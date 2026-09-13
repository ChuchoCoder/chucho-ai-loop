[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetPath,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Upgrade')]
    [ValidateSet('Claude', 'ChatGPT')]
    [string[]]$Assistants = @('Claude', 'ChatGPT'),

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Upgrade')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Doctor')]
    [switch]$Doctor,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Upgrade')]
    [switch]$Upgrade,

    [Parameter(ParameterSetName = 'Bootstrap')]
    [switch]$BootstrapRunner,

    # Alias compatible para automatizaciones que prefieren un único verbo.
    [ValidateSet('Install', 'Doctor', 'Status', 'Upgrade', 'BootstrapRunner')]
    [string]$Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DistributionRoot = $PSScriptRoot
$ManifestRelativePath = '.ai-loop/manifest.json'
$RunnerStateRelativePath = '.ai-loop/state/runner.json'

function Write-Result([string]$Message) { Write-Host "[ai-loop] $Message" }
function Stop-Install([string]$Message) { throw "chucho-ai-loop: $Message" }

function Get-FileHashString([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CanonicalPath([string]$Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-External([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { Stop-Install "Falló '$File $($Arguments -join ' ')'." }
}

function Get-GitOutput([string]$RepositoryPath, [string[]]$Arguments) {
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Install "Git no pudo ejecutar '$($Arguments -join ' ')': $($output -join [Environment]::NewLine)" }
    return ($output -join "`n").Trim()
}

function Get-GitHubRepository([string]$RepositoryPath) {
    $remote = Get-GitOutput $RepositoryPath @('remote', 'get-url', 'origin')
    $patterns = @(
        '^git@github\.com:(?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?$',
        '^https://github\.com/(?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?/?$',
        '^ssh://git@github\.com/(?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?/?$'
    )
    foreach ($pattern in $patterns) {
        if ($remote -match $pattern) { return $Matches.repo }
    }
    Stop-Install "origin debe apuntar a GitHub; se encontró '$remote'."
}

function Get-BaseBranch([string]$RepositoryPath, [string]$GitHubRepository) {
    $configured = Join-Path $RepositoryPath '.ai-loop/config.json'
    if (Test-Path -LiteralPath $configured) {
        try {
            $config = Get-Content -LiteralPath $configured -Raw | ConvertFrom-Json
            if ($config.baseBranch) { return [string]$config.baseBranch }
            if ($config.base_branch) { return [string]$config.base_branch }
        } catch { Stop-Install "No se puede leer .ai-loop/config.json: $($_.Exception.Message)" }
    }
    $branch = & gh repo view $GitHubRepository --json defaultBranchRef --jq '.defaultBranchRef.name' 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($branch -join '').Trim())) {
        Stop-Install "No se pudo determinar la rama base desde GitHub para $GitHubRepository."
    }
    return ($branch -join '').Trim()
}

function Test-Requirements([string]$RepositoryPath, [switch]$RequireGitHub) {
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($PSVersionTable.PSVersion.Major -lt 7) { $problems.Add('Se requiere PowerShell 7 o posterior.') }
    foreach ($command in @('git', 'gh')) {
        if (-not (Test-Command $command)) { $problems.Add("No se encontró '$command' en PATH.") }
    }
    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) { $problems.Add("No existe TargetPath: $RepositoryPath") }
    elseif (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) { $problems.Add('TargetPath no es un repositorio Git.') }
    if ($RequireGitHub -and (Test-Command 'gh')) {
        & gh auth status 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { $problems.Add("gh no tiene una sesión autenticada. Ejecutá 'gh auth login'.") }
    }
    return $problems
}

function Get-Manifest([string]$RepositoryPath) {
    $path = Join-Path $RepositoryPath $ManifestRelativePath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($parsed.files -is [hashtable]) { return $parsed.files }
        return @{}
    } catch { Stop-Install "El manifest existente no es JSON válido: $path" }
}

function Get-InstallFiles([string]$TargetRoot, [string[]]$SelectedAssistants) {
    $files = [System.Collections.Generic.List[object]]::new()
    $fixed = @(
        @{ Source = 'src/core.ps1'; Destination = '.ai-loop/core.ps1' },
        @{ Source = 'src/contract.md'; Destination = '.ai-loop/contract.md' },
        @{ Source = 'templates/.ai-loop/config.json'; Destination = '.ai-loop/config.json' }
    )
    foreach ($entry in $fixed) { $files.Add([pscustomobject]$entry) }
    $directories = [System.Collections.Generic.List[object]]::new()
    $directories.Add([pscustomobject]@{ Source = 'templates/.ai-loop/recipes'; Destination = '.ai-loop/recipes' })
    if ($SelectedAssistants -contains 'ChatGPT') { $directories.Add([pscustomobject]@{ Source = 'templates/.agents'; Destination = '.agents' }) }
    if ($SelectedAssistants -contains 'Claude') { $directories.Add([pscustomobject]@{ Source = 'templates/.claude'; Destination = '.claude' }) }
    foreach ($directory in $directories) {
        $sourceRoot = Join-Path $DistributionRoot $directory.Source
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { Stop-Install "Falta el recurso de distribución: $($directory.Source)" }
        Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | ForEach-Object {
            $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart([char]0x5c, [char]'/')
            $files.Add([pscustomobject]@{ Source = $_.FullName; Destination = (Join-Path $directory.Destination $relative) })
        }
    }
    foreach ($file in $files) {
        if (-not [System.IO.Path]::IsPathRooted($file.Source)) { $file.Source = Join-Path $DistributionRoot $file.Source }
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) { Stop-Install "Falta el recurso de distribución: $($file.Source)" }
    }
    return $files
}

function Get-DesiredContent([object]$File, [string[]]$SelectedAssistants, [string]$GitHubRepository, [string]$BaseBranch) {
    if ($File.Destination.Replace('\\', '/') -ne '.ai-loop/config.json') { return $null }
    try { $config = Get-Content -LiteralPath $File.Source -Raw | ConvertFrom-Json -AsHashtable }
    catch { Stop-Install "No se puede leer la plantilla de configuración: $($_.Exception.Message)" }
    $config.repository = $GitHubRepository
    $config.baseBranch = $BaseBranch
    $config.assistants = @($SelectedAssistants)
    return ($config | ConvertTo-Json -Depth 20)
}

function Get-DesiredHash([object]$File, [string[]]$SelectedAssistants, [string]$GitHubRepository, [string]$BaseBranch) {
    $content = Get-DesiredContent $File $SelectedAssistants $GitHubRepository $BaseBranch
    if ($null -eq $content) { return Get-FileHashString $File.Source }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($content)
    return ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function New-ManifestContent([hashtable]$Existing, [object[]]$Files, [string]$RepositoryPath, [string[]]$SelectedAssistants, [string]$GitHubRepository, [string]$BaseBranch) {
    $updated = @{}
    foreach ($key in $Existing.Keys) { $updated[$key] = $Existing[$key] }
    foreach ($file in $Files) {
        $destination = Join-Path $RepositoryPath $file.Destination
        if ((Test-Path -LiteralPath $destination -PathType Leaf) -and ((Get-FileHashString $destination) -eq (Get-DesiredHash $file $SelectedAssistants $GitHubRepository $BaseBranch))) {
            $updated[$file.Destination.Replace('\\', '/')] = Get-FileHashString $destination
        }
    }
    $orderedFiles = [ordered]@{}
    foreach ($key in ($updated.Keys | Sort-Object)) { $orderedFiles[$key] = $updated[$key] }
    return [ordered]@{ schemaVersion = 1; files = $orderedFiles }
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Update-GitIgnore([string]$RepositoryPath, [switch]$Preview) {
    $path = Join-Path $RepositoryPath '.gitignore'
    $entry = '.ai-loop/state/'
    $present = (Test-Path -LiteralPath $path) -and ((Get-Content -LiteralPath $path) -contains $entry)
    if ($present) { return }
    if ($Preview) { Write-Result "PLAN append $entry a .gitignore"; return }
    if (Test-Path -LiteralPath $path) {
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw.Length -gt 0 -and -not ($raw.EndsWith("`n") -or $raw.EndsWith("`r"))) {
            Add-Content -LiteralPath $path -Value '' -Encoding utf8NoBOM
        }
    }
    Add-Content -LiteralPath $path -Value $entry -Encoding utf8NoBOM
    Write-Result "Agregado $entry a .gitignore"
}

function Ensure-Labels([string]$GitHubRepository, [switch]$Preview) {
    $labels = @(
        @('priority/P0', 'b60205', 'Prioridad crítica'), @('priority/P1', 'd93f0b', 'Prioridad alta'),
        @('priority/P2', 'fbca04', 'Prioridad normal'), @('priority/P3', '0e8a16', 'Prioridad baja'),
        @('loop/planificando', '1d76db', 'Issue en planificación'), @('loop/en-dev', '0052cc', 'Issue en desarrollo'),
        @('loop/en-review', '5319e7', 'PR en revisión'), @('loop/corrigiendo', 'd4c5f9', 'Correcciones de revisión'),
        @('loop/review-final', '7057ff', 'Revisión final'), @('loop/espera-merge', 'bfdadc', 'Listo para merge humano'),
        @('loop/espera-auto', 'c5def5', 'Espera automática'), @('loop/necesita-humano', 'e11d48', 'Requiere decisión humana'),
        @('blocked', 'b60205', 'Bloqueado'), @('icebox', 'cfd3d7', 'Fuera de la cola activa')
    )
    if ($Preview) {
        foreach ($label in $labels) { Write-Result "PLAN ensure label $($label[0])" }
        return
    }
    $existingOutput = & gh label list -R $GitHubRepository --limit 10000 --json name --jq '.[].name' 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Install "No se pudieron listar las labels de ${GitHubRepository}: $($existingOutput -join [Environment]::NewLine)" }
    if (@($existingOutput).Count -ge 10000) { Stop-Install 'La lista de labels llegó al límite de 10000; no se puede comprobar si existen todas.' }
    $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $existingOutput) { if (-not [string]::IsNullOrWhiteSpace([string]$name)) { [void]$existing.Add(([string]$name).Trim()) } }
    foreach ($label in $labels) {
        if ($existing.Contains($label[0])) { Write-Result "Label existente: $($label[0])"; continue }
        Invoke-External 'gh' @('label', 'create', $label[0], '-R', $GitHubRepository, '--color', $label[1], '--description', $label[2])
    }
}

function Invoke-Install([string]$RepositoryPath, [string[]]$SelectedAssistants, [switch]$Preview) {
    $root = Get-CanonicalPath $RepositoryPath
    $problems = @(Test-Requirements $root -RequireGitHub)
    if ($problems.Count -gt 0) { Stop-Install ($problems -join ' ') }
    $githubRepository = Get-GitHubRepository $root
    $baseBranch = Get-BaseBranch $root $githubRepository
    $remoteBranch = & git -C $root ls-remote --exit-code origin "refs/heads/$baseBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Install "La rama base '${baseBranch}' no existe en origin." }
    $manifest = Get-Manifest $root
    $files = Get-InstallFiles $root $SelectedAssistants
    $copy = [System.Collections.Generic.List[object]]::new()
    $preserved = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $destination = Join-Path $root $file.Destination
        $key = $file.Destination.Replace('\\', '/')
        $sourceHash = Get-DesiredHash $file $SelectedAssistants $githubRepository $baseBranch
        if (-not (Test-Path -LiteralPath $destination)) { $copy.Add($file); continue }
        $destinationHash = Get-FileHashString $destination
        if ($destinationHash -eq $sourceHash) { continue }
        if ($manifest.ContainsKey($key) -and $manifest[$key] -eq $destinationHash) { $copy.Add($file); continue }
        $preserved.Add($file.Destination)
    }
    Write-Result "Repositorio: $githubRepository; rama base: $baseBranch"
    foreach ($file in $copy) { Write-Result "PLAN copy $($file.Destination)" }
    foreach ($file in $preserved) { Write-Result "PRESERVE editado por el usuario: $file" }
    Update-GitIgnore $root -Preview:$Preview
    Ensure-Labels $githubRepository -Preview:$Preview
    if ($Preview) { Write-Result 'DryRun completado: no se modificó el repositorio.'; return }
    foreach ($file in $copy) {
        $destination = Join-Path $root $file.Destination
        $directory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $content = Get-DesiredContent $file $SelectedAssistants $githubRepository $baseBranch
        if ($null -eq $content) { Copy-Item -LiteralPath $file.Source -Destination $destination -Force }
        else { [System.IO.File]::WriteAllText($destination, $content, [System.Text.UTF8Encoding]::new($false)) }
    }
    $manifestContent = New-ManifestContent $manifest $files $root $SelectedAssistants $githubRepository $baseBranch
    Write-JsonFile (Join-Path $root $ManifestRelativePath) $manifestContent
    Write-Result 'Instalación completada. Revisá los cambios, hacé commit y push antes de ejecutar -BootstrapRunner.'
}

function Invoke-Doctor([string]$RepositoryPath) {
    $root = [System.IO.Path]::GetFullPath($RepositoryPath)
    $problems = @(Test-Requirements $root -RequireGitHub)
    if (Test-Path -LiteralPath $root -PathType Container -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        try { Write-Result "GitHub: $(Get-GitHubRepository $root)" } catch { $problems += $_.Exception.Message }
    }
    if ($problems.Count -gt 0) { $problems | ForEach-Object { Write-Result "ERROR $_" }; exit 1 }
    Write-Result 'Doctor OK: PowerShell, Git, gh, autenticación y repositorio están listos.'
}

function Invoke-Status([string]$RepositoryPath) {
    $root = Get-CanonicalPath $RepositoryPath
    $manifest = Get-Manifest $root
    if ($manifest.Count -eq 0) { Write-Result 'No hay instalación registrada.'; return }
    foreach ($key in ($manifest.Keys | Sort-Object)) {
        $path = Join-Path $root $key
        $state = if (-not (Test-Path -LiteralPath $path)) { 'missing' } elseif ((Get-FileHashString $path) -eq $manifest[$key]) { 'managed' } else { 'modified' }
        Write-Result "$state $key"
    }
    $runnerState = Join-Path $root $RunnerStateRelativePath
    if (Test-Path -LiteralPath $runnerState) { Write-Result "runner $(Get-Content -LiteralPath $runnerState -Raw)" }
}

function Invoke-BootstrapRunner([string]$RepositoryPath) {
    $root = Get-CanonicalPath $RepositoryPath
    $problems = @(Test-Requirements $root -RequireGitHub)
    if ($problems.Count -gt 0) { Stop-Install ($problems -join ' ') }
    $githubRepository = Get-GitHubRepository $root
    $baseBranch = Get-BaseBranch $root $githubRepository
    Invoke-External 'git' @('-C', $root, 'fetch', 'origin', $baseBranch)
    $published = & git -C $root show "origin/${baseBranch}:.ai-loop/core.ps1" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($published -join ''))) {
        Stop-Install "Primero hacé commit y push de la instalación a origin/$baseBranch; el runner sólo usa archivos publicados."
    }
    $safeName = $githubRepository.Replace('/', '-').ToLowerInvariant()
    $runnerRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".ai-loop/$safeName/runner"
    if (Test-Path -LiteralPath $runnerRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $runnerRoot '.git'))) { Stop-Install "Runner existente no es Git: $runnerRoot" }
        if (Test-Path -LiteralPath (Join-Path $runnerRoot '.ai-loop/state/tick.lock')) {
            Stop-Install 'Hay un tick activo o un lock pendiente; detené las tareas y resolvé el lock antes de actualizar el runner.'
        }
        $runnerRemote = Get-GitHubRepository $runnerRoot
        if ($runnerRemote -ne $githubRepository) { Stop-Install "Runner existente apunta a $runnerRemote, no a $githubRepository." }
        $dirty = Get-GitOutput $runnerRoot @('status', '--porcelain')
        if ($dirty) { Stop-Install "Runner existente tiene cambios; limpiá o preservá ese checkout antes de actualizarlo." }
        Invoke-External 'git' @('-C', $runnerRoot, 'fetch', 'origin', $baseBranch)
        Invoke-External 'git' @('-C', $runnerRoot, 'checkout', $baseBranch)
        Invoke-External 'git' @('-C', $runnerRoot, 'pull', '--ff-only', 'origin', $baseBranch)
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $runnerRoot) -Force | Out-Null
        $originUrl = Get-GitOutput $root @('remote', 'get-url', 'origin')
        Invoke-External 'git' @('clone', '--branch', $baseBranch, '--single-branch', $originUrl, $runnerRoot)
    }
    $runnerConfigPath = Join-Path $runnerRoot '.ai-loop/config.json'
    try { $runnerConfig = Get-Content -LiteralPath $runnerConfigPath -Raw | ConvertFrom-Json } catch { Stop-Install "No se puede leer la configuración publicada del runner: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace([string]$runnerConfig.repository)) { Stop-Install 'La configuración publicada no declara repository.' }
    $state = [ordered]@{ root = (Get-CanonicalPath $runnerRoot); repository = [string]$runnerConfig.repository }
    # El control-plane se ejecuta desde el checkout dedicado, por eso su estado
    # local vive allí y nunca en el checkout desde el que se publicó la configuración.
    $statePath = Join-Path $runnerRoot $RunnerStateRelativePath
    if (Test-Path -LiteralPath $statePath) {
        try { $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { Stop-Install "No se puede leer ${RunnerStateRelativePath}: $($_.Exception.Message)" }
        if (-not $existingState.root -or $existingState.root -ne $state.root) {
            Stop-Install "$RunnerStateRelativePath ya apunta a otro runner; no se sobrescribe estado local existente."
        }
    } else {
        Write-JsonFile $statePath $state
    }
    Write-Result "Runner preparado en $($state.root)"
    $installedAssistants = @($runnerConfig.assistants)
    if ('ChatGPT' -in $installedAssistants) {
        Write-Result "Prompt ChatGPT Desktop (cada hora): En $($state.root), atendé un tick de Chucho AI Loop mediante la skill ai-loop-tick. Terminá si ScheduleGate no habilita esta ejecución."
    }
    if ('Claude' -in $installedAssistants) {
        Write-Result "Prompt Claude Desktop Routines → Local (cada hora): En $($state.root), ejecutá /ai-loop-tick. Terminá si ScheduleGate no habilita esta ejecución."
    }
    Write-Result 'Después de crear cada tarea local, usá Run now para verificar permisos y salida.'
}

$selectedAssistants = @($Assistants)
if ($Command -and $DryRun -and $Command -notin @('Install', 'Upgrade')) {
    Stop-Install "-DryRun no se admite con -Command $Command."
}
$isUpgrade = ($Command -eq 'Upgrade' -or $PSCmdlet.ParameterSetName -eq 'Upgrade')
if ($isUpgrade -and -not $PSBoundParameters.ContainsKey('Assistants')) {
    $existingConfigPath = Join-Path $TargetPath '.ai-loop/config.json'
    if (Test-Path -LiteralPath $existingConfigPath -PathType Leaf) {
        $existingConfig = Get-Content -LiteralPath $existingConfigPath -Raw | ConvertFrom-Json
        $selectedAssistants = @($existingConfig.assistants)
    }
}

if ($Command) {
    switch ($Command) {
        'Doctor' { Invoke-Doctor $TargetPath; exit }
        'Status' { Invoke-Status $TargetPath; exit }
        'BootstrapRunner' { Invoke-BootstrapRunner $TargetPath; exit }
        'Upgrade' { Invoke-Install $TargetPath $selectedAssistants -Preview:$DryRun; exit }
        'Install' { Invoke-Install $TargetPath $selectedAssistants -Preview:$DryRun; exit }
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Doctor' { Invoke-Doctor $TargetPath }
    'Status' { Invoke-Status $TargetPath }
    'Bootstrap' { Invoke-BootstrapRunner $TargetPath }
    'Upgrade' { Invoke-Install $TargetPath $selectedAssistants -Preview:$DryRun }
    default { Invoke-Install $TargetPath $selectedAssistants -Preview:$DryRun }
}
