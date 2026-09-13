#!/usr/bin/env pwsh
param([switch]$KeepTemporaryFiles, [string]$Only = '')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chucho-ai-loop-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$script:passed = 0
$script:failed = 0
$env:AI_LOOP_REAL_GIT = (Get-Command git).Source
$stubDirectory = Join-Path $temporaryRoot 'bin'
New-Item -ItemType Directory -Path $stubDirectory | Out-Null
$env:AI_LOOP_GH_LOG = Join-Path $temporaryRoot 'gh.log'
$env:AI_LOOP_GH_FIXTURE = ''
if ($IsWindows) {
    $wrapper = '@echo off' + [Environment]::NewLine + 'pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'fixtures/gh.ps1') + '" %*' + [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $stubDirectory 'gh.cmd') -Value $wrapper -NoNewline
    $gitWrapper = '@echo off' + [Environment]::NewLine + 'pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'fixtures/git.ps1') + '" %*' + [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $stubDirectory 'git.cmd') -Value $gitWrapper -NoNewline
} else {
    $wrapper = '#!/bin/sh' + [Environment]::NewLine + 'exec pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'fixtures/gh.ps1') + '" "$@"' + [Environment]::NewLine
    $wrapperPath = Join-Path $stubDirectory 'gh'
    Set-Content -LiteralPath $wrapperPath -Value $wrapper -NoNewline
    & chmod +x $wrapperPath
    $gitWrapper = '#!/bin/sh' + [Environment]::NewLine + 'exec pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'fixtures/git.ps1') + '" "$@"' + [Environment]::NewLine
    $gitWrapperPath = Join-Path $stubDirectory 'git'
    Set-Content -LiteralPath $gitWrapperPath -Value $gitWrapper -NoNewline
    & chmod +x $gitWrapperPath
}
$env:PATH = $stubDirectory + [IO.Path]::PathSeparator + $env:PATH
$remoteDirectory = Join-Path $temporaryRoot 'remotes'
New-Item -ItemType Directory -Path $remoteDirectory | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (actual: $Actual; esperado: $Expected)" }
}

function Invoke-Cli([string]$Script, [string[]]$Arguments) {
    $output = & pwsh -NoProfile -File $Script @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String).Trim() }
}

function Invoke-Core([string]$Root, [string[]]$Arguments) {
    $core = Join-Path $projectRoot 'src/core.ps1'
    Assert-True (Test-Path -LiteralPath $core) 'Falta src/core.ps1'
    $result = Invoke-Cli $core (@('-Root', $Root) + $Arguments)
    if ($result.ExitCode -ne 0) { return $result }
    try { $result | Add-Member -NotePropertyName Json -NotePropertyValue ($result.Output | ConvertFrom-Json -Depth 50) }
    catch { throw "El control-plane no devolvió JSON: $($result.Output)" }
    return $result
}

function Invoke-ValidateMerge([string]$Root, [string[]]$Arguments) {
    $lock = Invoke-Core $Root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
    Assert-Equal $lock.ExitCode 0 $lock.Output
    Assert-True $lock.Json.Acquired 'No se adquirió lock para ValidateMerge'
    try { return (Invoke-Core $Root (@('-Command', 'ValidateMerge', '-Token', $lock.Json.Token) + $Arguments)) }
    finally { $null = Invoke-Core $Root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply') }
}

function New-TestRepository([string]$Name) {
    $root = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    & git -C $root init -q -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init falló' }
    $bareRemote = Join-Path $remoteDirectory "$Name.git"
    & git init --bare -q $bareRemote | Out-Null
    & git -C $root remote add origin "https://github.com/demo/$Name.git" | Out-Null
    & git -C $root config user.name 'Test User' | Out-Null
    & git -C $root config user.email 'test@example.invalid' | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'README.md') -Value "# $Name" -NoNewline
    & git -C $root add README.md | Out-Null
    & git -C $root commit -qm 'initial' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git commit falló' }
    & $env:AI_LOOP_REAL_GIT -C $root push -q $bareRemote main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git push local falló' }
    return $root
}

function Write-TestConfig([string]$Root) {
    $configDir = Join-Path $Root '.ai-loop'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $config = [ordered]@{
        schemaVersion = 1
        repository = "demo/$(Split-Path -Leaf $Root)"
        baseBranch = 'main'
        assistants = @('Claude', 'ChatGPT')
        testCommands = @('pwsh -NoProfile -Command "exit 0"')
        activeLimit = 1
        maxReviewRounds = 2
        merge = @{ mode = 'manual'; requiredChecks = @() }
    }
    $env:AI_LOOP_FIXTURE_REPO = $config.repository
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $configDir 'config.json')
    $stateDir = Join-Path $configDir 'state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    @{ root = (Resolve-Path -LiteralPath $Root).Path; repository = $config.repository } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'runner.json')
}

function Set-GhFixture([string]$Root, [object[]]$PullRequests, [object]$Detail, [object[]]$Checks, [object[]]$Threads, [object[]]$Comments, [string]$IssueState = 'espera-merge', [int]$MergeExitCode = 0) {
    if (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) { Clear-Content -LiteralPath $env:AI_LOOP_GH_LOG }
    $issue = @{ number = 17; state = 'open'; labels = @(@{ name = "loop/$IssueState" }, @{ name = 'priority/P2' }) }
    $detail.statusCheckRollup = $Checks
    $fixture = @{ responses = @(
        @{ pattern = '^api repos/demo/.*/issues/17$'; output = $issue },
        @{ pattern = '^pr list\b'; output = $PullRequests },
        @{ pattern = '^pr view 31\b'; output = $Detail },
        @{ pattern = '^pr merge 31\b'; output = ''; exitCode = $MergeExitCode },
        @{ pattern = '^api graphql\b'; output = @{ data = @{ repository = @{ pullRequest = @{ mergeQueueEntry = $null; reviewThreads = @{ pageInfo = @{ hasNextPage = $false }; nodes = $Threads } } } } } },
        @{ pattern = '^api repos/demo/.*/issues/31/comments'; output = $Comments },
        @{ pattern = '^api user\b'; output = 'tester' },
        @{ pattern = '^issue list\b'; output = @() }
    ) }
    $path = Join-Path $Root 'gh-fixture.json'
    $fixture | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path
    $env:AI_LOOP_GH_FIXTURE = $path
}

function New-PrFixture([string]$Sha) {
    $repositoryName = $env:AI_LOOP_FIXTURE_REPO.Split('/')[1]
    return @{ number = 31; state = 'OPEN'; isDraft = $false; headRefName = 'ai-loop/issue-17'; headRefOid = $Sha; headRepository = @{ nameWithOwner = $env:AI_LOOP_FIXTURE_REPO }; baseRefName = 'main'; closingIssuesReferences = @(@{ number = 17; repository = @{ owner = @{ login = 'demo' }; name = $repositoryName } }); mergeStateStatus = 'CLEAN'; statusCheckRollup = @() }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Only -and $Name -notmatch $Only) { return }
    try {
        & $Body
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        $script:failed++
        Write-Host "FAIL $Name`: $_" -ForegroundColor Red
    }
}

try {
    Test-Case 'dry-run no modifica el repositorio' {
        $root = New-TestRepository 'dry-run'
        $before = @(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty Name | Sort-Object)
        $result = Invoke-Cli (Join-Path $projectRoot 'install.ps1') @('-TargetPath', $root, '-Assistants', 'Claude', '-DryRun')
        Assert-Equal $result.ExitCode 0 $result.Output
        $after = @(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty Name | Sort-Object)
        Assert-Equal ($after -join '|') ($before -join '|') 'dry-run creó archivos'
    }

    Test-Case 'BootstrapRunner rechaza DryRun explícitamente' {
        $root = New-TestRepository 'bootstrap-dry-run'
        $result = Invoke-Cli (Join-Path $projectRoot 'install.ps1') @('-Command', 'BootstrapRunner', '-TargetPath', $root, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'BootstrapRunner aceptó DryRun'
        Assert-True ($result.Output -match 'DryRun') "Falta diagnóstico: $($result.Output)"
    }

    Test-Case 'instalación repetida conserva cambios del usuario' {
        $root = New-TestRepository 'idempotent'
        $installer = Join-Path $projectRoot 'install.ps1'
        $first = Invoke-Cli $installer @('-TargetPath', $root, '-Assistants', 'Claude')
        Assert-Equal $first.ExitCode 0 $first.Output
        $configPath = Join-Path $root '.ai-loop/config.json'
        Assert-True (Test-Path -LiteralPath $configPath) 'Falta config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        Assert-Equal $config.schemaVersion 1 'Versión de config inválida'
        Assert-Equal $config.merge.mode 'manual' 'Merge debe ser manual por defecto'
        $marker = 'user-owned-change'
        $config | Add-Member -NotePropertyName customNote -NotePropertyValue $marker
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        $second = Invoke-Cli $installer @('-TargetPath', $root, '-Assistants', 'Claude')
        Assert-Equal $second.ExitCode 0 $second.Output
        Assert-True ((Get-Content -LiteralPath $configPath -Raw).Contains($marker)) 'Instalación repetida pisó cambios'
    }

    Test-Case 'upgrade conserva archivos editados' {
        $root = New-TestRepository 'upgrade'
        $installer = Join-Path $projectRoot 'install.ps1'
        $first = Invoke-Cli $installer @('-TargetPath', $root, '-Assistants', 'Claude')
        Assert-Equal $first.ExitCode 0 $first.Output
        $contract = Join-Path $root '.ai-loop/contract.md'
        if (-not (Test-Path -LiteralPath $contract)) {
            $contract = @(Get-ChildItem -LiteralPath (Join-Path $root '.ai-loop') -Recurse -File -Filter '*contract*' | Select-Object -First 1 -ExpandProperty FullName)[0]
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($contract)) 'Falta contrato instalado'
        $marker = 'CUSTOM CONTRACT CONTENT'
        Add-Content -LiteralPath $contract -Value $marker
        $upgrade = Invoke-Cli $installer @('-Upgrade', '-TargetPath', $root, '-Assistants', 'Claude')
        Assert-Equal $upgrade.ExitCode 0 $upgrade.Output
        Assert-True ((Get-Content -LiteralPath $contract -Raw).Contains($marker)) 'Upgrade pisó el contrato editado'
    }

    Test-Case 'lock compartido excluye un segundo tick y valida token' {
        $root = New-TestRepository 'lock'
        Write-TestConfig $root
        $first = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-Equal $first.ExitCode 0 $first.Output
        Assert-True $first.Json.Acquired 'No se adquirió lock inicial'
        Assert-True (-not [string]::IsNullOrWhiteSpace($first.Json.Token)) 'Falta token de lock'
        $second = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'ChatGPT', '-Apply')
        Assert-Equal $second.ExitCode 0 $second.Output
        Assert-True (-not $second.Json.Acquired) 'Dos asistentes adquirieron el mismo lock'
        $wrongRelease = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', 'wrong-token', '-Apply')
        Assert-True ($wrongRelease.ExitCode -ne 0 -or -not $wrongRelease.Json.Released) 'Token ajeno liberó lock'
        $release = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $first.Json.Token, '-Apply')
        Assert-Equal $release.ExitCode 0 $release.Output
        Assert-True $release.Json.Released 'Dueño no pudo liberar lock'
    }

    Test-Case 'ticks simultáneos tienen un solo dueño' {
        $root = New-TestRepository 'simultaneous-lock'
        Write-TestConfig $root
        $core = Join-Path $projectRoot 'src/core.ps1'
        $jobs = @(1..2 | ForEach-Object {
            $assistant = if ($_ -eq 1) { 'Claude' } else { 'ChatGPT' }
            Start-Job -ScriptBlock {
                param($Core, $Root, $Assistant)
                $text = & pwsh -NoProfile -File $Core -Command AcquireLock -Root $Root -Assistant $Assistant -Apply 2>&1
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($text | Out-String).Trim() }
            } -ArgumentList $core, $root, $assistant
        })
        try {
            $jobs | Wait-Job | Out-Null
            $results = @($jobs | Receive-Job)
            Assert-Equal $results.Count 2 'Faltan respuestas de ticks'
            $owners = @($results | Where-Object { $_.ExitCode -eq 0 -and ($_.Output | ConvertFrom-Json).Acquired })
            Assert-Equal $owners.Count 1 'Debe existir exactamente un dueño del lock'
            $token = ($owners[0].Output | ConvertFrom-Json).Token
            $release = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $token, '-Apply')
            Assert-Equal $release.ExitCode 0 $release.Output
        } finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'lock vencido no se recupera automáticamente' {
        $root = New-TestRepository 'stale-lock'
        Write-TestConfig $root
        $path = Join-Path $root '.ai-loop/state/tick.lock'
        @{ token = 'old-owner'; acquiredUtc = '2020-01-01T00:00:00.0000000Z'; processId = 1; machine = 'other-host' } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $path
        $result = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'ChatGPT', '-Apply')
        Assert-Equal $result.ExitCode 0 $result.Output
        Assert-True (-not $result.Json.Acquired) 'Lock vencido fue robado automáticamente'
        Assert-True ($result.Json.Reason -match 'stale|inspect') 'Falta diagnóstico de recuperación manual'
        Assert-Equal ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).token) 'old-owner' 'Cambió dueño del lock vencido'
    }

    Test-Case 'transición inválida se rechaza' {
        $root = New-TestRepository 'invalid-transition'
        Write-TestConfig $root
        $pr = New-PrFixture ('a' * 40)
        Set-GhFixture $root @() $pr @() @() @() 'planificando'
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para transición'
        try {
            $result = Invoke-Core $root @('-Command', 'Transition', '-Issue', '17', '-FromState', 'planificando', '-ToState', 'espera-merge', '-Token', $lock.Json.Token, '-Apply')
            Assert-True ($result.ExitCode -ne 0 -or -not $result.Json.Allowed) 'Se aceptó un salto de estados inválido'
            Assert-True ($result.Output -match 'transition|Transition|invalid|Invalid') "Falta diagnóstico de transición: $($result.Output)"
        } finally {
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }

    Test-Case 'merge manual nunca ejecuta squash automático' {
        $root = New-TestRepository 'manual-merge'
        Write-TestConfig $root
        $sha = 'a' * 40
        $pr = New-PrFixture $sha
        Set-GhFixture $root @($pr) $pr @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @()
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para merge'
        $before = if (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) { (Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Measure-Object -Line).Lines } else { 0 }
        try {
            $result = Invoke-Core $root @('-Command', 'Merge', '-Issue', '17', '-Pr', '31', '-Token', $lock.Json.Token, '-ExpectedHeadSha', $sha, '-Apply')
            Assert-True ($result.ExitCode -ne 0 -or -not $result.Json.Merged) 'Modo manual ejecutó merge'
            Assert-True ($result.Output -match 'manual') "Falta diagnóstico de modo manual: $($result.Output)"
            $newCalls = @()
            if (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) { $newCalls = @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Select-Object -Skip $before) }
            Assert-True (-not (@($newCalls | Where-Object { $_ -match '^pr merge\b' }).Count)) 'Se llamó gh pr merge en modo manual'
        } finally {
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }

    Test-Case 'ScheduleGate alterna sin mutar el repo' {
        $root = New-TestRepository 'schedule'
        Write-TestConfig $root
        $a = Invoke-Core $root @('-Command', 'ScheduleGate', '-Assistant', 'Claude', '-AtUtc', '2026-01-01T00:00:00Z')
        $b = Invoke-Core $root @('-Command', 'ScheduleGate', '-Assistant', 'ChatGPT', '-AtUtc', '2026-01-01T00:00:00Z')
        Assert-Equal $a.ExitCode 0 $a.Output
        Assert-Equal $b.ExitCode 0 $b.Output
        Assert-True ($a.Json.Run -xor $b.Json.Run) 'En un tick debe correr un solo asistente'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.ai-loop/state/tick.lock'))) 'ScheduleGate creó lock'
    }

    Test-Case 'Status incluye snapshot de issues cerrados' {
        $root = New-TestRepository 'status-closed'
        Write-TestConfig $root
        $fixture = @{ responses = @(
            @{ pattern = '^issue list .*--state open\b'; output = @() },
            @{ pattern = '^issue list .*--state closed\b'; output = @(@{ number = 17; labels = @(@{ name = 'loop/espera-merge' }) }) },
            @{ pattern = '^pr list\b'; output = @() }
        ) }
        $path = Join-Path $root 'status-fixture.json'
        $fixture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $env:AI_LOOP_GH_FIXTURE = $path
        $result = Invoke-Core $root @('-Command', 'Status')
        Assert-Equal $result.ExitCode 0 $result.Output
        Assert-Equal $result.Json.Snapshot.ClosedWithLoopState[0].Issue 17 'Status omitió issue cerrado con estado del loop'
    }

    Test-Case 'tres issues pendientes bloquean intake nuevo' {
        $root = New-TestRepository 'pending-capacity'
        Write-TestConfig $root
        $candidate = @{ number = 17; state = 'open'; title = 'Nuevo trabajo'; createdAt = '2026-01-01T00:00:00Z'; labels = @(@{ name = 'priority/P2' }) }
        $open = @($candidate,
            @{ number = 18; state = 'open'; labels = @(@{ name = 'loop/espera-merge' }) },
            @{ number = 19; state = 'open'; labels = @(@{ name = 'loop/espera-auto' }) },
            @{ number = 20; state = 'open'; labels = @(@{ name = 'loop/necesita-humano' }) })
        $fixture = @{ responses = @(
            @{ pattern = '^api repos/demo/.*/issues/17$'; output = $candidate },
            @{ pattern = '^issue list .*--state open\b'; output = $open },
            @{ pattern = '^issue list .*--state closed\b'; output = @() },
            @{ pattern = '^pr list\b'; output = @() }
        ) }
        $path = Join-Path $root 'pending-fixture.json'
        $fixture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $env:AI_LOOP_GH_FIXTURE = $path
        $status = Invoke-Core $root @('-Command', 'Status')
        Assert-Equal $status.ExitCode 0 $status.Output
        Assert-Equal @($status.Json.Snapshot.Pending).Count 3 'Conteo pending incorrecto'
        Assert-Equal @($status.Json.Snapshot.Candidates).Count 1 'Candidato no aparece'
        $transition = Invoke-Core $root @('-Command', 'Transition', '-Issue', '17', '-FromState', 'none', '-ToState', 'planificando')
        Assert-True ($transition.ExitCode -ne 0) 'Se admitió intake sobre pendingLimit'
        Assert-True ($transition.Output -match 'Pending issue capacity is full') "Falta diagnóstico de capacidad: $($transition.Output)"
    }

    Test-Case 'reingreso desde espera-auto respeta cupo activo' {
        $root = New-TestRepository 'reentry-capacity'
        Write-TestConfig $root
        $fixture = @{ responses = @(
            @{ pattern = '^api repos/demo/.*/issues/17$'; output = @{ number = 17; state = 'open'; labels = @(@{ name = 'loop/espera-auto' }, @{ name = 'priority/P2' }) } },
            @{ pattern = '^issue list .*--state open\b'; output = @(
                @{ number = 17; labels = @(@{ name = 'loop/espera-auto' }) },
                @{ number = 18; labels = @(@{ name = 'loop/en-dev' }) }) },
            @{ pattern = '^issue list .*--state closed\b'; output = @() },
            @{ pattern = '^pr list\b'; output = @() }
        ) }
        $path = Join-Path $root 'reentry-fixture.json'
        $fixture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $env:AI_LOOP_GH_FIXTURE = $path
        $result = Invoke-Core $root @('-Command', 'Transition', '-Issue', '17', '-FromState', 'espera-auto', '-ToState', 'en-dev')
        Assert-True ($result.ExitCode -ne 0) 'Reingreso excedió activeLimit'
        Assert-True ($result.Output -match 'capacity|Capacity') "Falta diagnóstico de cupo: $($result.Output)"
    }

    Test-Case 'PrepareSlot crea un worktree de issue sin cambiar la rama principal' {
        $root = New-TestRepository 'prepare-slot'
        Write-TestConfig $root
        & git -C $root remote set-url origin (Join-Path $remoteDirectory 'prepare-slot.git') | Out-Null
        $pr = New-PrFixture ('a' * 40)
        Set-GhFixture $root @() $pr @() @() @() 'en-dev'
        $mainBranch = (& git -C $root branch --show-current).Trim()
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para preparar slot'
        try {
            $result = Invoke-Core $root @('-Command', 'PrepareSlot', '-Issue', '17', '-Token', $lock.Json.Token, '-Apply')
            Assert-Equal $result.ExitCode 0 $result.Output
            Assert-True $result.Json.Created 'No se creó el slot'
            $slot = Join-Path $root '.ai-loop/state/worktrees/issue-17'
            Assert-True (Test-Path -LiteralPath $slot) 'Falta worktree de issue'
            Assert-Equal ((& git -C $slot branch --show-current).Trim()) 'ai-loop/issue-17' 'Rama de issue incorrecta'
            Assert-Equal ((& git -C $root branch --show-current).Trim()) $mainBranch 'Cambió rama del checkout principal'
        } finally {
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }

    Test-Case 'SweepClosed conserva worktree sucio y su label' {
        $root = New-TestRepository 'sweep-dirty'
        Write-TestConfig $root
        $slot = Join-Path $root '.ai-loop/state/worktrees/issue-17'
        New-Item -ItemType Directory -Path (Split-Path -Parent $slot) -Force | Out-Null
        & git -C $root worktree add -q -b ai-loop/issue-17 $slot HEAD | Out-Null
        Assert-Equal $LASTEXITCODE 0 'No se creó worktree para SweepClosed'
        Set-Content -LiteralPath (Join-Path $slot 'unsaved.txt') -Value 'keep me'
        $fixture = @{ responses = @(
            @{ pattern = '^api repos/demo/.*/issues/17$'; output = @{ number = 17; state = 'closed'; labels = @(@{ name = 'loop/espera-merge' }) } },
            @{ pattern = '^pr list\b'; output = @() }
        ) }
        $path = Join-Path $root 'sweep-fixture.json'
        $fixture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $env:AI_LOOP_GH_FIXTURE = $path
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para SweepClosed'
        $before = if (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) { (Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Measure-Object -Line).Lines } else { 0 }
        try {
            $result = Invoke-Core $root @('-Command', 'SweepClosed', '-Issue', '17', '-Token', $lock.Json.Token, '-Apply')
            Assert-True ($result.ExitCode -ne 0) 'SweepClosed borró slot sucio'
            Assert-True ($result.Output -match 'dirty|clean|changes') "Falta diagnóstico de worktree sucio: $($result.Output)"
            Assert-True (Test-Path -LiteralPath (Join-Path $slot 'unsaved.txt')) 'SweepClosed eliminó trabajo sin guardar'
            $newCalls = @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Select-Object -Skip $before)
            Assert-True (-not (@($newCalls | Where-Object { $_ -match '^issue edit\b' }).Count)) 'SweepClosed quitó label pese a slot sucio'
        } finally {
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }

    Test-Case 'guarded rechaza SHA cambiado, CI faltante, threads y autorización ausente' {
        $root = New-TestRepository 'merge-gates'
        Write-TestConfig $root
        $configPath = Join-Path $root '.ai-loop/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.merge.mode = 'guarded'
        $config.merge.requiredChecks = @('build')
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        & git -C $root add .ai-loop/config.json | Out-Null
        & git -C $root commit -qm 'configure guarded merge' | Out-Null
        $sha = 'a' * 40
        $pr = New-PrFixture $sha
        Set-GhFixture $root @($pr) $pr @() @(@{ isResolved = $false }) @()
        $assessment = Invoke-ValidateMerge $root @('-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', ('b' * 40))
        Assert-Equal $assessment.ExitCode 0 $assessment.Output
        Assert-True (-not $assessment.Json.CanMerge) 'Aceptó señales incompletas'
        $reasons = $assessment.Json.Reasons -join '|'
        foreach ($expected in @('head changed', 'Required CI checks are absent', 'unresolved review threads', 'authorization')) {
            Assert-True ($reasons -match [regex]::Escape($expected)) "Falta rechazo: $expected; razones: $reasons"
        }
        $duplicate = New-PrFixture $sha
        $duplicate.number = 32
        Set-GhFixture $root @($pr, $duplicate) $pr @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @(@{ body = "<!-- ai-loop:merge-authorized issue=17 pr=31 sha=$sha -->"; user = @{ login = 'tester' } })
        $assessment = Invoke-ValidateMerge $root @('-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha)
        Assert-Equal $assessment.ExitCode 0 $assessment.Output
        Assert-True (-not $assessment.Json.CanMerge) 'PR duplicado habilitó merge'
        Assert-True (($assessment.Json.Reasons -join '|') -match 'more than one open closing PR') 'Falta diagnóstico de PR duplicado'
        $fork = New-PrFixture $sha
        $fork.headRepository.nameWithOwner = 'someone/fork'
        Set-GhFixture $root @($fork) $fork @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @()
        $assessment = Invoke-ValidateMerge $root @('-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha)
        Assert-Equal $assessment.ExitCode 0 $assessment.Output
        Assert-True (-not $assessment.Json.CanMerge) 'PR de fork habilitó merge'
        Assert-True (($assessment.Json.Reasons -join '|') -match 'head repository|fork|repository') 'Falta diagnóstico de PR de otro repositorio'
    }

    Test-Case 'InspectPullRequest rechaza dos PR abiertos para un issue' {
        $root = New-TestRepository 'duplicate-pr'
        Write-TestConfig $root
        $sha = 'a' * 40
        $pr1 = New-PrFixture $sha
        $pr2 = New-PrFixture $sha
        $pr2.number = 32
        Set-GhFixture $root @($pr1, $pr2) $pr1 @() @() @()
        $result = Invoke-Core $root @('-Command', 'InspectPullRequest', '-Issue', '17')
        Assert-True ($result.ExitCode -ne 0) 'Se aceptaron dos PR asociados'
        Assert-True ($result.Output -match 'more than one open closing PR') "Falta diagnóstico de duplicado: $($result.Output)"
    }

    Test-Case 'guarded mergea sólo el SHA autorizado y comprueba MERGED' {
        $root = New-TestRepository 'guarded-success'
        Write-TestConfig $root
        $configPath = Join-Path $root '.ai-loop/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.merge.mode = 'guarded'
        $config.merge.requiredChecks = @('build')
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        & git -C $root add .ai-loop/config.json | Out-Null
        & git -C $root commit -qm 'configure guarded merge' | Out-Null
        $slot = Join-Path $root '.ai-loop/state/worktrees/issue-17'
        New-Item -ItemType Directory -Path (Split-Path -Parent $slot) -Force | Out-Null
        & git -C $root worktree add -q -b ai-loop/issue-17 $slot HEAD | Out-Null
        Assert-Equal $LASTEXITCODE 0 'No se pudo crear worktree real'
        $sha = (& git -C $slot rev-parse HEAD).Trim()
        $pr = New-PrFixture $sha
        $comment = @{ body = "<!-- ai-loop:merge-authorized issue=17 pr=31 sha=$sha -->"; user = @{ login = 'tester' } }
        Set-GhFixture $root @($pr) $pr @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @($comment)
        $assessment = Invoke-ValidateMerge $root @('-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha)
        Assert-Equal $assessment.ExitCode 0 $assessment.Output
        Assert-True $assessment.Json.CanMerge "Validación positiva fue rechazada: $($assessment.Json.Reasons -join '; ')"
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para merge positivo'
        $env:AI_LOOP_GH_AFTER_MERGE_STATE = '1'
        try {
            $merged = Invoke-Core $root @('-Command', 'Merge', '-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha, '-Token', $lock.Json.Token, '-Apply')
            Assert-Equal $merged.ExitCode 0 $merged.Output
            Assert-True $merged.Json.Merged "Merge positivo rechazado: $($merged.Json.Reasons -join '; ')"
            $calls = @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Where-Object { $_ -match '^pr merge 31\b' })
            Assert-Equal $calls.Count 1 'Se esperaba un solo gh pr merge'
            Assert-True ($calls[0] -match '--squash' -and $calls[0] -match "--match-head-commit $sha") 'Faltan gates del comando squash'
            Assert-True ($calls[0] -notmatch '--auto|--admin') 'Se usaron flags de bypass'
        } finally {
            $env:AI_LOOP_GH_AFTER_MERGE_STATE = ''
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }

    Test-Case 'guarded rechaza tests locales fallidos sin llamar merge' {
        $root = New-TestRepository 'guarded-failing-tests'
        Write-TestConfig $root
        $configPath = Join-Path $root '.ai-loop/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.merge.mode = 'guarded'
        $config.merge.requiredChecks = @('build')
        $config.testCommands = @('exit 1')
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        & git -C $root add .ai-loop/config.json | Out-Null
        & git -C $root commit -qm 'configure failing test' | Out-Null
        $slot = Join-Path $root '.ai-loop/state/worktrees/issue-17'
        New-Item -ItemType Directory -Path (Split-Path -Parent $slot) -Force | Out-Null
        & git -C $root worktree add -q -b ai-loop/issue-17 $slot HEAD | Out-Null
        Assert-Equal $LASTEXITCODE 0 'No se creó worktree real'
        $sha = (& git -C $slot rev-parse HEAD).Trim()
        $pr = New-PrFixture $sha
        $comment = @{ body = "<!-- ai-loop:merge-authorized issue=17 pr=31 sha=$sha -->"; user = @{ login = 'tester' } }
        Set-GhFixture $root @($pr) $pr @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @($comment)
        $beforeMergeCalls = if (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) { @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Where-Object { $_ -match '^pr merge\b' }).Count } else { 0 }
        $assessment = Invoke-ValidateMerge $root @('-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha)
        Assert-Equal $assessment.ExitCode 0 $assessment.Output
        Assert-True (-not $assessment.Json.CanMerge) 'Tests locales fallidos habilitaron merge'
        Assert-True (($assessment.Json.Reasons -join '|') -match 'test|Test') 'Falta diagnóstico de tests locales'
        $calls = @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Where-Object { $_ -match '^pr merge\b' })
        Assert-Equal $calls.Count $beforeMergeCalls 'Se llamó gh pr merge con tests fallidos'
    }

    Test-Case 'merge consulta estado final aunque gh pr merge devuelva error' {
        $root = New-TestRepository 'merge-postcheck'
        Write-TestConfig $root
        $configPath = Join-Path $root '.ai-loop/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.merge.mode = 'guarded'
        $config.merge.requiredChecks = @('build')
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        & git -C $root add .ai-loop/config.json | Out-Null
        & git -C $root commit -qm 'configure guarded merge' | Out-Null
        $slot = Join-Path $root '.ai-loop/state/worktrees/issue-17'
        New-Item -ItemType Directory -Path (Split-Path -Parent $slot) -Force | Out-Null
        & git -C $root worktree add -q -b ai-loop/issue-17 $slot HEAD | Out-Null
        Assert-Equal $LASTEXITCODE 0 'No se creó worktree real'
        $sha = (& git -C $slot rev-parse HEAD).Trim()
        $pr = New-PrFixture $sha
        $comment = @{ body = "<!-- ai-loop:merge-authorized issue=17 pr=31 sha=$sha -->"; user = @{ login = 'tester' } }
        Set-GhFixture $root @($pr) $pr @(@{ name = 'build'; conclusion = 'SUCCESS' }) @() @($comment) 'espera-merge' 1
        $lock = Invoke-Core $root @('-Command', 'AcquireLock', '-Assistant', 'Claude', '-Apply')
        Assert-True $lock.Json.Acquired 'No se adquirió lock para postcheck'
        $env:AI_LOOP_GH_AFTER_MERGE_STATE = '1'
        try {
            $result = Invoke-Core $root @('-Command', 'Merge', '-Issue', '17', '-Pr', '31', '-ExpectedHeadSha', $sha, '-Token', $lock.Json.Token, '-Apply')
            Assert-Equal $result.ExitCode 0 $result.Output
            Assert-True $result.Json.Merged "Se ignoró estado MERGED posterior al error de gh: $($result.Output)"
            $calls = @(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Where-Object { $_ -match '^pr view 31\b' })
            Assert-True ($calls.Count -ge 2) 'Faltó releer PR después de gh pr merge'
        } finally {
            $env:AI_LOOP_GH_AFTER_MERGE_STATE = ''
            $null = Invoke-Core $root @('-Command', 'ReleaseLock', '-Token', $lock.Json.Token, '-Apply')
        }
    }
} finally {
    if (-not $KeepTemporaryFiles) {
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $resolved.StartsWith($tempBase, $comparison) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^chucho-ai-loop-tests-[0-9a-f]{32}$') {
            throw "Unsafe temporary test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    else { Write-Host "Temporales: $temporaryRoot" }
}

Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
