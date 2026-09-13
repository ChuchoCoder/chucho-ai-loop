<#
.SYNOPSIS
    Shared GitHub control plane for an installed Chucho AI Loop.

.DESCRIPTION
    Agents may plan, edit, test, create pull requests and review. Only this script changes
    loop labels, issue worktrees or merges a pull request. Decisions use fresh GitHub data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Doctor', 'Status', 'ScheduleGate', 'AcquireLock', 'ReleaseLock',
        'Transition', 'PrepareSlot', 'InspectPullRequest', 'ValidateMerge', 'Merge', 'SweepClosed')]
    [string]$Command,
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$Issue,
    [int]$Pr,
    [string]$FromState = 'none',
    [string]$ToState,
    [string]$Token,
    [ValidateSet('Claude', 'ChatGPT')][string]$Assistant,
    [string]$ExpectedHeadSha,
    [datetime]$AtUtc = [datetime]::UtcNow,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$StateLabels = [ordered]@{
    'planificando' = 'loop/planificando'
    'en-dev' = 'loop/en-dev'
    'en-review' = 'loop/en-review'
    'corrigiendo' = 'loop/corrigiendo'
    'review-final' = 'loop/review-final'
    'espera-merge' = 'loop/espera-merge'
    'espera-auto' = 'loop/espera-auto'
    'necesita-humano' = 'loop/necesita-humano'
}
$Transitions = @{
    'none' = @('planificando')
    'planificando' = @('en-dev', 'espera-auto', 'necesita-humano', 'none')
    'en-dev' = @('en-review', 'espera-auto', 'necesita-humano')
    'en-review' = @('corrigiendo', 'review-final', 'espera-auto', 'necesita-humano')
    'corrigiendo' = @('en-review', 'review-final', 'espera-auto', 'necesita-humano')
    'review-final' = @('corrigiendo', 'espera-merge', 'espera-auto', 'necesita-humano')
    'espera-merge' = @()
    'espera-auto' = @('planificando', 'en-dev', 'en-review', 'corrigiendo', 'review-final', 'necesita-humano')
    'necesita-humano' = @('planificando', 'en-dev', 'en-review', 'review-final', 'none')
}
$ActiveStates = @('planificando', 'en-dev', 'en-review', 'corrigiendo', 'review-final')
$PendingStates = @('espera-merge', 'espera-auto', 'necesita-humano')
$PrStates = @('en-review', 'corrigiendo', 'review-final', 'espera-merge')

function Write-Result {
    param($Value)
    $Value | ConvertTo-Json -Depth 30 -Compress
}

function Get-Property {
    param($Value, [string]$Name, $Default = $null)
    if ($null -eq $Value) { return $Default }
    $item = $Value.PSObject.Properties[$Name]
    if ($null -eq $item -or $null -eq $item.Value) { return $Default }
    return $item.Value
}

function Invoke-NativeText {
    param([string]$Executable, [string[]]$Arguments)
    $output = & $Executable @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$Executable failed ($code): $(@($Arguments) -join ' ') :: $(@($output) -join [Environment]::NewLine)"
    }
    return (@($output) -join [Environment]::NewLine).Trim()
}

function Invoke-NativeJson {
    param([string]$Executable, [string[]]$Arguments)
    $value = Invoke-NativeText $Executable $Arguments
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return ($value | ConvertFrom-Json -Depth 40)
}

function Get-CanonicalPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-Config {
    $path = Join-Path $Root '.ai-loop/config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing config: $path" }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 30
    if ([int](Get-Property $config 'schemaVersion' 0) -ne 1) { throw 'Unsupported config schemaVersion.' }
    $repo = [string](Get-Property $config 'repository' '')
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository in config.' }
    $branch = [string](Get-Property $config 'baseBranch' '')
    if ([string]::IsNullOrWhiteSpace($branch) -or $branch.StartsWith('-')) { throw 'Invalid baseBranch in config.' }
    $assistants = @((Get-Property $config 'assistants' @()))
    if ($assistants.Count -lt 1 -or $assistants.Count -gt 2 -or
        @($assistants | Where-Object { $_ -notin @('Claude', 'ChatGPT') }).Count -gt 0 -or
        @($assistants | Select-Object -Unique).Count -ne $assistants.Count) {
        throw 'assistants must contain Claude, ChatGPT, or both once.'
    }
    if ([int](Get-Property $config 'activeLimit' 0) -ne 1) { throw 'Version 1 supports activeLimit=1.' }
    if ([int](Get-Property $config 'pendingLimit' 3) -lt 1) { throw 'pendingLimit must be positive.' }
    if ([int](Get-Property $config 'maxReviewRounds' 0) -lt 1) { throw 'maxReviewRounds must be positive.' }
    $testCommands = @((Get-Property $config 'testCommands' @()))
    if ($testCommands.Count -eq 0 -or @($testCommands | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
        throw 'Configure one or more non-empty testCommands before running the loop.'
    }
    $merge = Get-Property $config 'merge'
    if ($null -eq $merge -or (Get-Property $merge 'mode' '') -notin @('manual', 'guarded')) {
        throw 'merge.mode must be manual or guarded.'
    }
    if ($merge.mode -eq 'guarded' -and @((Get-Property $merge 'requiredChecks' @())).Count -eq 0) {
        throw 'Guarded merge requires one or more requiredChecks.'
    }
    return $config
}

function Get-Repository {
    param($Config)
    return [string]$Config.repository
}

function Get-StateDir {
    return (Join-Path $Root '.ai-loop/state')
}

function Assert-Runner {
    param($Config)
    $markerPath = Join-Path (Get-StateDir) 'runner.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'Runner is not registered. Bootstrap a dedicated checkout and use it for scheduled tasks.'
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $actual = Get-CanonicalPath $Root
    $expected = Get-CanonicalPath ([string](Get-Property $marker 'root' ''))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($actual, $expected, $comparison)) { throw 'Runner marker belongs to a different checkout.' }
    if ((Get-Property $marker 'repository' '') -ne (Get-Repository $Config)) { throw 'Runner repository differs from config.' }
}

function Get-LockPath {
    return (Join-Path (Get-StateDir) 'tick.lock')
}

function Read-Lock {
    $path = Get-LockPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { throw 'Lock file is unreadable. Stop both scheduled tasks and inspect it manually.' }
}

function Assert-Lock {
    param([string]$OwnerToken)
    if ([string]::IsNullOrWhiteSpace($OwnerToken)) { throw 'A lock token is required.' }
    $held = Read-Lock
    if ($null -eq $held -or [string](Get-Property $held 'token' '') -cne $OwnerToken) {
        throw 'The run does not own the current lock.'
    }
    $rawTime = Get-Property $held 'acquiredUtc'
    if ($rawTime -is [datetime]) { $acquired = $rawTime.ToUniversalTime() }
    else { $acquired = [datetime]::Parse([string]$rawTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    if (([datetime]::UtcNow - $acquired).TotalHours -gt 2) {
        throw 'Lock exceeded the two-hour run budget. Stop and inspect the task before recovery.'
    }
}

function Acquire-LoopLock {
    param($Config)
    Assert-Runner $Config
    $state = Get-StateDir
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $path = Get-LockPath
    $newToken = [guid]::NewGuid().ToString('N')
    $data = @{ token = $newToken; acquiredUtc = [datetime]::UtcNow.ToString('o'); processId = $PID; machine = [Environment]::MachineName }
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = [IO.StreamWriter]::new($stream)
            $writer.Write(($data | ConvertTo-Json -Compress))
            $writer.Flush()
            $writer.Dispose()
        } finally { $stream.Dispose() }
        return @{ Acquired = $true; Token = $newToken; Reason = $null }
    } catch [IO.IOException] {
        $existing = Read-Lock
        return @{ Acquired = $false; Token = $null; Reason = 'Another run owns the lock. If stale, pause both tasks and inspect it manually.'; Existing = $existing }
    }
}

function Release-LoopLock {
    param([string]$OwnerToken)
    $held = Read-Lock
    if ($null -eq $held) { return @{ Released = $false; Reason = 'No lock exists.' } }
    if ([string]$held.token -cne $OwnerToken) { throw 'The run does not own the lock.' }
    Remove-Item -LiteralPath (Get-LockPath) -Force
    return @{ Released = $true }
}

function Get-LoopState {
    param($Labels)
    $names = @($Labels | ForEach-Object {
        if ($_ -is [string]) { $_ } else { [string](Get-Property $_ 'name' '') }
    } | Where-Object { $_ -like 'loop/*' })
    if ($names.Count -gt 1) { throw "Ambiguous loop labels: $($names -join ', ')" }
    if ($names.Count -eq 0) { return 'none' }
    foreach ($state in $StateLabels.Keys) {
        if ($names[0] -ceq $StateLabels[$state]) { return $state }
    }
    throw "Unknown loop label: $($names[0])"
}

function Get-Issue {
    param([int]$Number, $Config)
    if ($Number -le 0) { throw 'Issue number must be positive.' }
    $value = Invoke-NativeJson gh @('api', "repos/$(Get-Repository $Config)/issues/$Number")
    if ($null -eq $value -or $null -ne (Get-Property $value 'pull_request')) { throw "#$Number is not a GitHub issue." }
    return $value
}

function Get-OpenIssues {
    param($Config)
    $value = Invoke-NativeJson gh @('issue', 'list', '-R', (Get-Repository $Config), '--state', 'open', '-L', '10000', '--json', 'number,title,labels,createdAt')
    $issues = @($value)
    if ($issues.Count -ge 10000) { throw 'Issue snapshot reached the 10000-item limit; refusing incomplete capacity data.' }
    return $issues
}

function Get-ClosedIssues {
    param($Config)
    $byNumber = @{}
    foreach ($label in $StateLabels.Values) {
        $value = Invoke-NativeJson gh @('issue', 'list', '-R', (Get-Repository $Config), '--state', 'closed', '--label', [string]$label, '-L', '10000', '--json', 'number,labels')
        $issues = @($value)
        if ($issues.Count -ge 10000) { throw "Closed issues with $label reached the 10000-item limit." }
        foreach ($item in $issues) { $byNumber[[string]$item.number] = $item }
    }
    return @($byNumber.Values)
}

function Get-OpenPullRequests {
    param($Config)
    $value = Invoke-NativeJson gh @('pr', 'list', '-R', (Get-Repository $Config), '--state', 'open', '-L', '10000', '--json', 'number,headRefName,headRefOid,headRepository,baseRefName,closingIssuesReferences,isDraft,mergeStateStatus,statusCheckRollup')
    $prs = @($value)
    if ($prs.Count -ge 10000) { throw 'PR snapshot reached the 10000-item limit; refusing incomplete association data.' }
    return $prs
}

function Get-IssuePullRequest {
    param([int]$Number, $Config)
    $matches = @()
    foreach ($candidate in @(Get-OpenPullRequests $Config)) {
        foreach ($reference in @((Get-Property $candidate 'closingIssuesReferences' @()))) {
            $referenceRepository = Get-Property $reference 'repository'
            $referenceOwner = Get-Property (Get-Property $referenceRepository 'owner') 'login' ''
            $referenceName = Get-Property $referenceRepository 'name' ''
            if ([int](Get-Property $reference 'number' 0) -eq $Number -and
                "$referenceOwner/$referenceName" -ieq [string]$Config.repository) {
                $matches += $candidate
                break
            }
        }
    }
    if ($matches.Count -gt 1) { throw "Issue #$Number has more than one open closing PR." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-SlotPath {
    param([int]$Number)
    return (Join-Path (Get-StateDir) "worktrees/issue-$Number")
}

function Assert-Slot {
    param([int]$Number, [string]$Branch, [switch]$RequireClean)
    $slot = Get-SlotPath $Number
    if (-not (Test-Path -LiteralPath $slot -PathType Container)) { throw "Issue #$Number has no worktree slot." }
    $top = Invoke-NativeText git @('-C', $slot, 'rev-parse', '--show-toplevel')
    if ((Get-CanonicalPath $top) -ne (Get-CanonicalPath $slot)) { throw "Issue #$Number slot is not its own worktree." }
    $current = Invoke-NativeText git @('-C', $slot, 'branch', '--show-current')
    if ($current -cne $Branch) { throw "Issue #$Number slot branch differs from its PR." }
    if ($RequireClean) {
        $dirty = Invoke-NativeText git @('-C', $slot, 'status', '--porcelain')
        if (-not [string]::IsNullOrWhiteSpace($dirty)) { throw "Issue #$Number worktree is dirty." }
    }
    return $slot
}

function Get-ReviewMarkers {
    param([int]$Number, $Config)
    $comments = @(Invoke-NativeJson gh @('api', "repos/$(Get-Repository $Config)/issues/$Number/comments?per_page=100"))
    if ($comments.Count -ge 100) { throw 'Issue comments reached the 100-item limit; review count is incomplete.' }
    $actor = Invoke-NativeText gh @('api', 'user', '--jq', '.login')
    $markers = @()
    foreach ($comment in $comments) {
        if ([string](Get-Property (Get-Property $comment 'user') 'login' '') -cne $actor) { continue }
        $body = [string](Get-Property $comment 'body' '')
        $match = [regex]::Match($body, '<!-- ai-loop:review-round:(\d+) sha=([0-9a-f]{40}) -->')
        if ($match.Success) {
            $markers += @{ Round = [int]$match.Groups[1].Value; Sha = $match.Groups[2].Value }
        }
    }
    for ($index = 0; $index -lt $markers.Count; $index++) {
        if ($markers[$index].Round -ne ($index + 1)) { throw 'Review round markers are missing, repeated, or out of order.' }
    }
    return $markers
}

function Get-StatusSnapshot {
    param($Config)
    $candidates = @()
    $active = @()
    $pending = @()
    $ambiguous = @()
    $closedWithLoopState = @()
    foreach ($item in @(Get-OpenIssues $Config)) {
        $state = 'none'
        try { $state = Get-LoopState (Get-Property $item 'labels' @()) }
        catch { $ambiguous += @{ Issue = $item.number; Reason = $_.Exception.Message }; continue }
        $labels = @((Get-Property $item 'labels' @()) | ForEach-Object { [string](Get-Property $_ 'name' '') })
        if ($state -in $ActiveStates) { $active += @{ Issue = $item.number; State = $state } }
        if ($state -in $PendingStates) { $pending += @{ Issue = $item.number; State = $state } }
        if ($state -eq 'none' -and 'blocked' -notin $labels -and 'icebox' -notin $labels) {
            foreach ($priority in @('priority/P0', 'priority/P1', 'priority/P2', 'priority/P3')) {
                if ($priority -in $labels) {
                    $candidates += @{ Issue = $item.number; Priority = $priority; CreatedAt = $item.createdAt; Title = $item.title }
                    break
                }
            }
        }
    }
    foreach ($item in @(Get-ClosedIssues $Config)) {
        try {
            $state = Get-LoopState (Get-Property $item 'labels' @())
            if ($state -ne 'none') { $closedWithLoopState += @{ Issue = $item.number; State = $state } }
        } catch { $ambiguous += @{ Issue = $item.number; Reason = $_.Exception.Message } }
    }
    $sorted = @($candidates | Sort-Object @{ Expression = { [int]($_.Priority.Substring(10)) } }, CreatedAt)
    return @{ Active = $active; Pending = $pending; Candidates = $sorted; ClosedWithLoopState = $closedWithLoopState; Ambiguous = $ambiguous; Capacity = [int]$Config.activeLimit; PendingCapacity = [int](Get-Property $Config 'pendingLimit' 3) }
}

function Assert-Transition {
    param([string]$Actual, [string]$Destination, [int]$Number, $Config)
    if (-not $Transitions.ContainsKey($Actual) -or $Destination -notin $Transitions[$Actual]) {
        throw "Transition $Actual -> $Destination is not allowed."
    }
    if (($Destination -in $ActiveStates -and $Actual -notin $ActiveStates) -or
        ($Destination -in $PendingStates -and $Actual -notin $PendingStates)) {
        $snapshot = Get-StatusSnapshot $Config
        if ($Destination -in $ActiveStates -and @($snapshot.Active).Count -ge [int]$Config.activeLimit) {
            throw 'Active issue capacity is full.'
        }
        if ($Destination -in $PendingStates -and @($snapshot.Pending).Count -ge [int](Get-Property $Config 'pendingLimit' 3)) {
            throw 'Pending issue capacity is full.'
        }
    }
    if ($Actual -eq 'none' -and $Destination -eq 'planificando') {
        if (@($snapshot.Ambiguous).Count -gt 0) { throw 'Ambiguous issue state blocks new intake.' }
        if (@($snapshot.Pending).Count -ge [int](Get-Property $Config 'pendingLimit' 3)) { throw 'Pending issue capacity is full.' }
        $live = Get-Issue $Number $Config
        $labels = @((Get-Property $live 'labels' @()) | ForEach-Object { [string](Get-Property $_ 'name' '') })
        if ('blocked' -in $labels -or 'icebox' -in $labels) { throw 'Issue is excluded from intake.' }
        if (@($labels | Where-Object { $_ -in @('priority/P0', 'priority/P1', 'priority/P2', 'priority/P3') }).Count -ne 1) {
            throw 'Issue must have exactly one priority/P0..P3 label.'
        }
    }
    if (($Actual -eq 'en-review' -and $Destination -eq 'corrigiendo') -or
        ($Actual -eq 'corrigiendo' -and $Destination -eq 'en-review')) {
        $markers = @(Get-ReviewMarkers $Number $Config)
        if ($markers.Count -eq 0) { throw 'A review-round marker is required for correction work.' }
        $association = Assert-PrAssociation $Number $Config -RequireClean
        $head = [string]$association.Pr.headRefOid
        if ($Actual -eq 'en-review') {
            if ($markers.Count -gt [int]$Config.maxReviewRounds) { throw 'Review round limit reached; use review-final.' }
            if ($markers[-1].Sha -cne $head) { throw 'Latest review marker must cite the current PR head.' }
        } elseif ($markers[-1].Sha -ceq $head) {
            throw 'Corrections must publish a new PR head before returning to review.'
        }
    }
}

function Assert-PrAssociation {
    param([int]$Number, $Config, [switch]$RequireClean)
    $candidate = Get-IssuePullRequest $Number $Config
    if ($null -eq $candidate) { throw "Issue #$Number has no open closing PR." }
    $expectedBranch = "ai-loop/issue-$Number"
    if ([string]$candidate.headRefName -cne $expectedBranch) { throw "PR branch must be $expectedBranch." }
    if ([string]$candidate.baseRefName -cne [string]$Config.baseBranch) { throw 'PR base branch differs from config.' }
    $headRepository = [string](Get-Property (Get-Property $candidate 'headRepository') 'nameWithOwner' '')
    if ($headRepository -ine [string]$Config.repository) { throw 'PR head must belong to the configured repository, not a fork.' }
    $slot = Assert-Slot $Number $expectedBranch -RequireClean:$RequireClean
    $slotHead = Invoke-NativeText git @('-C', $slot, 'rev-parse', 'HEAD')
    if ($slotHead -cne [string]$candidate.headRefOid) { throw 'Issue worktree HEAD differs from the PR head SHA.' }
    return @{ Pr = $candidate; Slot = $slot }
}

function Apply-Transition {
    param([int]$Number, [string]$ExpectedState, [string]$Destination, $Config, [string]$OwnerToken)
    Assert-Lock $OwnerToken
    $live = Get-Issue $Number $Config
    if ([string]$live.state -ne 'open') { throw "Issue #$Number is closed." }
    $actual = Get-LoopState (Get-Property $live 'labels' @())
    if ($actual -cne $ExpectedState) { throw "Stale transition: expected $ExpectedState, found $actual." }
    Assert-Transition $actual $Destination $Number $Config
    if ($Destination -in $PrStates) { $null = Assert-PrAssociation $Number $Config -RequireClean }
    $arguments = @('issue', 'edit', [string]$Number, '-R', (Get-Repository $Config))
    if ($actual -ne 'none') { $arguments += @('--remove-label', [string]$StateLabels[$actual]) }
    if ($Destination -ne 'none') { $arguments += @('--add-label', [string]$StateLabels[$Destination]) }
    Assert-Lock $OwnerToken
    $null = Invoke-NativeText gh $arguments
    $after = Get-Issue $Number $Config
    $newState = Get-LoopState (Get-Property $after 'labels' @())
    if ($newState -cne $Destination) { throw "Transition did not reach $Destination; inspect issue labels." }
    return @{ Changed = $true; Issue = $Number; From = $actual; To = $Destination }
}

function Prepare-IssueSlot {
    param([int]$Number, $Config, [string]$OwnerToken)
    Assert-Lock $OwnerToken
    $live = Get-Issue $Number $Config
    if ((Get-LoopState (Get-Property $live 'labels' @())) -ne 'en-dev') { throw 'PrepareSlot requires loop/en-dev.' }
    $slot = Get-SlotPath $Number
    $branch = "ai-loop/issue-$Number"
    $branchPrs = @(Get-OpenPullRequests $Config | Where-Object { [string]$_.headRefName -ceq $branch })
    if ($branchPrs.Count -gt 1) { throw "More than one open PR uses $branch." }
    $existingPr = Get-IssuePullRequest $Number $Config
    if ($branchPrs.Count -eq 1 -and ($null -eq $existingPr -or [int]$branchPrs[0].number -ne [int]$existingPr.number)) {
        throw "Open PR on $branch does not close issue #$Number."
    }
    if (Test-Path -LiteralPath $slot) {
        $validated = Assert-Slot $Number $branch
        return @{ Created = $false; Path = $validated; Branch = $branch }
    }
    if ($null -ne $existingPr) { throw 'PR exists but its issue worktree is missing; manual recovery required.' }
    $null = Invoke-NativeText git @('-C', $Root, 'fetch', 'origin', [string]$Config.baseBranch)
    $parent = Split-Path -Parent $slot
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    Assert-Lock $OwnerToken
    $null = Invoke-NativeText git @('-C', $Root, 'worktree', 'add', '-b', $branch, $slot, "origin/$($Config.baseBranch)")
    return @{ Created = $true; Path = $slot; Branch = $branch }
}

function Get-ReviewThreadSummary {
    param([int]$Number, $Config)
    $parts = ([string]$Config.repository).Split('/')
    $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){mergeQueueEntry{id} reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}'
    $result = Invoke-NativeJson gh @('api', 'graphql', '-f', "query=$query", '-F', "owner=$($parts[0])", '-F', "name=$($parts[1])", '-F', "number=$Number")
    $pull = $result.data.repository.pullRequest
    if ($null -eq $pull) { throw 'PR review thread query returned no PR.' }
    $threads = $pull.reviewThreads
    if ([bool]$threads.pageInfo.hasNextPage) { throw 'PR review threads exceed 100; refusing incomplete review data.' }
    $unresolved = @(@($threads.nodes) | Where-Object { -not [bool]$_.isResolved }).Count
    return @{ Unresolved = $unresolved; MergeQueueEntry = (Get-Property $pull 'mergeQueueEntry') }
}

function Get-PrDetail {
    param([int]$Number, $Config)
    return (Invoke-NativeJson gh @('pr', 'view', [string]$Number, '-R', (Get-Repository $Config), '--json', 'number,state,isDraft,headRefName,headRefOid,headRepository,baseRefName,closingIssuesReferences,mergeStateStatus,statusCheckRollup'))
}

function Invoke-ConfiguredTests {
    param($Config, [string]$Slot)
    foreach ($testCommand in @($Config.testCommands)) {
        Push-Location -LiteralPath $Slot
        try {
            $output = & pwsh -NoProfile -NonInteractive -Command ([string]$testCommand) 2>&1 | Select-Object -Last 20
            $exitCode = $LASTEXITCODE
        } finally { Pop-Location }
        if ($exitCode -ne 0) {
            throw "Local test command failed ($exitCode): $testCommand :: $(@($output) -join ' ')"
        }
    }
}

function Get-MergeAssessment {
    param([int]$IssueNumber, [int]$PrNumber, [string]$ExpectedSha, $Config)
    $reasons = [Collections.Generic.List[string]]::new()
    if ($Config.merge.mode -ne 'guarded') { $reasons.Add('merge.mode is manual.') }
    if ($Config.merge.mode -eq 'guarded') {
        try {
            Assert-Runner $Config
            $dirtyConfig = Invoke-NativeText git @('-C', $Root, 'status', '--porcelain', '--', '.ai-loop/config.json')
            if ($dirtyConfig) { $reasons.Add('Guarded merge requires committed config.json in the runner.') }
            $committedText = Invoke-NativeText git @('-C', $Root, 'show', 'HEAD:.ai-loop/config.json')
            $committed = $committedText | ConvertFrom-Json
            if ([string]$committed.merge.mode -ne 'guarded') {
                $reasons.Add('Guarded merge must be enabled in the committed configuration.')
            }
        } catch { $reasons.Add("Guarded configuration cannot be verified: $($_.Exception.Message)") }
    }
    $issueValue = Get-Issue $IssueNumber $Config
    $state = Get-LoopState (Get-Property $issueValue 'labels' @())
    if ($state -ne 'espera-merge') { $reasons.Add('Issue is not in loop/espera-merge.') }
    $associated = $null
    try { $associated = Assert-PrAssociation $IssueNumber $Config -RequireClean }
    catch { $reasons.Add($_.Exception.Message) }
    $prValue = Get-PrDetail $PrNumber $Config
    if ($null -eq $associated -or [int]$associated.Pr.number -ne $PrNumber) { $reasons.Add('PR is not the unique closing PR for this issue.') }
    $detailHeadRepository = [string](Get-Property (Get-Property $prValue 'headRepository') 'nameWithOwner' '')
    if ($detailHeadRepository -ine [string]$Config.repository) { $reasons.Add('PR head belongs to another repository.') }
    if ([string]$prValue.state -ne 'OPEN') { $reasons.Add('PR is not open.') }
    if ([bool]$prValue.isDraft) { $reasons.Add('PR is draft.') }
    if ([string]$prValue.mergeStateStatus -ne 'CLEAN') { $reasons.Add('PR merge state is not CLEAN.') }
    $head = [string]$prValue.headRefOid
    if ($head -notmatch '^[0-9a-f]{40}$') { $reasons.Add('PR head SHA is missing or invalid.') }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha) -and $head -cne $ExpectedSha) { $reasons.Add('PR head changed from expected SHA.') }
    $required = @($Config.merge.requiredChecks)
    $checks = @((Get-Property $prValue 'statusCheckRollup' @()))
    if ($required.Count -eq 0 -or $checks.Count -eq 0) { $reasons.Add('Required CI checks are absent.') }
    foreach ($name in $required) {
        $matching = @($checks | Where-Object {
            [string](Get-Property $_ 'name' (Get-Property $_ 'context' '')) -ceq [string]$name
        })
        if ($matching.Count -ne 1 -or
            [string](Get-Property $matching[0] 'conclusion' (Get-Property $matching[0] 'state' '')) -ne 'SUCCESS') {
            $reasons.Add("Required check '$name' is missing or not successful.")
        }
    }
    foreach ($check in $checks) {
        $conclusion = [string](Get-Property $check 'conclusion' (Get-Property $check 'state' ''))
        if ($conclusion -notin @('SUCCESS', 'NEUTRAL', 'SKIPPED')) {
            $reasons.Add("Check '$([string](Get-Property $check 'name' (Get-Property $check 'context' 'unknown')))' is not complete and green.")
        }
    }
    try {
        $threads = Get-ReviewThreadSummary $PrNumber $Config
        if ($threads.Unresolved -gt 0) { $reasons.Add('PR has unresolved review threads.') }
        if ($null -ne $threads.MergeQueueEntry) { $reasons.Add('PR is in a merge queue.') }
    } catch { $reasons.Add($_.Exception.Message) }
    $comments = @(Invoke-NativeJson gh @('api', "repos/$(Get-Repository $Config)/issues/$PrNumber/comments?per_page=100"))
    if ($comments.Count -ge 100) { $reasons.Add('PR comments exceed 100; authorization cannot be enumerated completely.') }
    $actor = Invoke-NativeText gh @('api', 'user', '--jq', '.login')
    $marker = "<!-- ai-loop:merge-authorized issue=$IssueNumber pr=$PrNumber sha=$head -->"
    $matchingComments = @($comments | Where-Object {
        [string](Get-Property $_ 'body' '') -ceq $marker -and
        [string](Get-Property (Get-Property $_ 'user') 'login' '') -ceq $actor
    })
    if ($matchingComments.Count -eq 0) { $reasons.Add('Exact final-review authorization for this SHA is absent.') }
    if ($reasons.Count -eq 0) {
        try {
            Invoke-ConfiguredTests $Config ([string]$associated.Slot)
            $afterTests = Assert-PrAssociation $IssueNumber $Config -RequireClean
            if ([string]$afterTests.Pr.headRefOid -cne $head) { throw 'PR head changed while local tests were running.' }
        } catch { $reasons.Add($_.Exception.Message) }
    }
    return @{ CanMerge = ($reasons.Count -eq 0); Reasons = $reasons.ToArray(); HeadSha = $head; Issue = $IssueNumber; Pr = $PrNumber }
}

function Invoke-GuardedMerge {
    param([int]$IssueNumber, [int]$PrNumber, [string]$OwnerToken, [string]$ExpectedSha, $Config)
    Assert-Lock $OwnerToken
    $assessment = Get-MergeAssessment $IssueNumber $PrNumber $ExpectedSha $Config
    if (-not $assessment.CanMerge) { return @{ Merged = $false; Reasons = $assessment.Reasons; HeadSha = $assessment.HeadSha } }
    Assert-Lock $OwnerToken
    $mergeError = $null
    try {
        $null = Invoke-NativeText gh @('pr', 'merge', [string]$PrNumber, '-R', (Get-Repository $Config), '--squash', '--delete-branch', '--match-head-commit', [string]$assessment.HeadSha)
    } catch { $mergeError = $_.Exception.Message }
    $after = Get-PrDetail $PrNumber $Config
    if ([string]$after.state -ne 'MERGED') {
        $why = if ($mergeError) { $mergeError } else { 'GitHub did not report PR as MERGED after merge command.' }
        return @{ Merged = $false; Reasons = @($why); HeadSha = $assessment.HeadSha }
    }
    return @{ Merged = $true; Reasons = @(); HeadSha = $assessment.HeadSha }
}

function Clear-ClosedIssue {
    param([int]$Number, [string]$OwnerToken, $Config)
    Assert-Lock $OwnerToken
    $live = Get-Issue $Number $Config
    if ([string]$live.state -ne 'closed') { throw 'SweepClosed requires a closed issue.' }
    $state = Get-LoopState (Get-Property $live 'labels' @())
    $slot = Get-SlotPath $Number
    $removedSlot = $false
    if (Test-Path -LiteralPath $slot -PathType Container) {
        $branch = "ai-loop/issue-$Number"
        $openPrs = @(Get-OpenPullRequests $Config | Where-Object { [string]$_.headRefName -ceq $branch })
        if ($openPrs.Count -gt 0) { throw "Issue #$Number still has an open PR for its worktree branch." }
        $slot = Assert-Slot $Number $branch -RequireClean
        Assert-Lock $OwnerToken
        $null = Invoke-NativeText git @('-C', $Root, 'worktree', 'remove', $slot)
        $removedSlot = $true
    }
    if ($state -ne 'none') {
        Assert-Lock $OwnerToken
        $null = Invoke-NativeText gh @('issue', 'edit', [string]$Number, '-R', (Get-Repository $Config), '--remove-label', [string]$StateLabels[$state])
        $after = Get-Issue $Number $Config
        if ((Get-LoopState (Get-Property $after 'labels' @())) -ne 'none') { throw 'Closed issue still has a loop state label.' }
    }
    return @{ Changed = ($removedSlot -or $state -ne 'none'); Issue = $Number; From = $state; To = 'none'; WorktreeRemoved = $removedSlot }
}

$Root = Get-CanonicalPath $Root
$config = Get-Config

switch ($Command) {
    'ScheduleGate' {
        if ([string]::IsNullOrWhiteSpace($Assistant)) { throw 'ScheduleGate requires -Assistant.' }
        $enabled = @($config.assistants)
        if ($Assistant -notin $enabled) { Write-Result @{ Run = $false; Reason = 'Assistant is not enabled.' }; break }
        $chosen = if ($enabled.Count -eq 1) { $enabled[0] } else { $enabled[[int]($AtUtc.ToUniversalTime().Hour % 2)] }
        Write-Result @{ Run = ($Assistant -eq $chosen); Selected = $chosen; HourUtc = $AtUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:00:00Z') }
    }
    'Doctor' {
        $checks = [Collections.Generic.List[object]]::new()
        foreach ($tool in @('pwsh', 'git', 'gh')) {
            $found = $null -ne (Get-Command $tool -ErrorAction SilentlyContinue)
            $checks.Add(@{ Name = $tool; Ok = $found })
        }
        $remote = ''
        try { $remote = Invoke-NativeText git @('-C', $Root, 'remote', 'get-url', 'origin') }
        catch { $checks.Add(@{ Name = 'origin'; Ok = $false; Detail = $_.Exception.Message }) }
        if ($remote) {
            $matchesRepo = $remote -match [regex]::Escape(([string]$config.repository)) + '(?:\.git)?$'
            $checks.Add(@{ Name = 'origin'; Ok = $matchesRepo; Detail = $remote })
        }
        try { Assert-Runner $config; $checks.Add(@{ Name = 'runner'; Ok = $true }) }
        catch { $checks.Add(@{ Name = 'runner'; Ok = $false; Detail = $_.Exception.Message }) }
        try { $null = Invoke-NativeText gh @('api', 'user', '--jq', '.login'); $checks.Add(@{ Name = 'gh-auth'; Ok = $true }) }
        catch { $checks.Add(@{ Name = 'gh-auth'; Ok = $false; Detail = $_.Exception.Message }) }
        $ready = @($checks | Where-Object { -not $_.Ok }).Count -eq 0
        Write-Result @{ Ready = $ready; Checks = @($checks); Repository = $config.repository }
    }
    'Status' {
        $snapshot = Get-StatusSnapshot $config
        $held = Read-Lock
        Write-Result @{ Repository = $config.repository; Snapshot = $snapshot; Lock = $held }
    }
    'AcquireLock' {
        if (-not $Apply) { throw 'AcquireLock requires -Apply.' }
        Write-Result (Acquire-LoopLock $config)
    }
    'ReleaseLock' {
        if (-not $Apply) { throw 'ReleaseLock requires -Apply.' }
        Write-Result (Release-LoopLock $Token)
    }
    'Transition' {
        if ($Issue -le 0 -or [string]::IsNullOrWhiteSpace($ToState)) { throw 'Transition requires -Issue and -ToState.' }
        if (-not $Apply) {
            $live = Get-Issue $Issue $config
            $state = Get-LoopState (Get-Property $live 'labels' @())
            if ($state -cne $FromState) { throw "Stale transition: expected $FromState, found $state." }
            Assert-Transition $state $ToState $Issue $config
            if ($ToState -in $PrStates) { $null = Assert-PrAssociation $Issue $config -RequireClean }
            Write-Result @{ Allowed = $true; Issue = $Issue; From = $state; To = $ToState }
        } else {
            Assert-Runner $config
            Write-Result (Apply-Transition $Issue $FromState $ToState $config $Token)
        }
    }
    'PrepareSlot' {
        if (-not $Apply -or $Issue -le 0) { throw 'PrepareSlot requires -Apply and -Issue.' }
        Assert-Runner $config
        Write-Result (Prepare-IssueSlot $Issue $config $Token)
    }
    'InspectPullRequest' {
        if ($Issue -le 0) { throw 'InspectPullRequest requires -Issue.' }
        $association = Assert-PrAssociation $Issue $config
        Write-Result @{ Issue = $Issue; PullRequest = $association.Pr; Slot = $association.Slot }
    }
    'ValidateMerge' {
        if ($Issue -le 0 -or $Pr -le 0 -or $ExpectedHeadSha -notmatch '^[0-9a-f]{40}$') {
            throw 'ValidateMerge requires -Issue, -Pr and an exact 40-character -ExpectedHeadSha.'
        }
        Assert-Runner $config
        Assert-Lock $Token
        Write-Result (Get-MergeAssessment $Issue $Pr $ExpectedHeadSha $config)
    }
    'Merge' {
        if (-not $Apply -or $Issue -le 0 -or $Pr -le 0 -or $ExpectedHeadSha -notmatch '^[0-9a-f]{40}$') {
            throw 'Merge requires -Apply, -Issue, -Pr and an exact 40-character -ExpectedHeadSha.'
        }
        Assert-Runner $config
        Write-Result (Invoke-GuardedMerge $Issue $Pr $Token $ExpectedHeadSha $config)
    }
    'SweepClosed' {
        if (-not $Apply -or $Issue -le 0) { throw 'SweepClosed requires -Apply and -Issue.' }
        Assert-Runner $config
        Write-Result (Clear-ClosedIssue $Issue $Token $config)
    }
}
