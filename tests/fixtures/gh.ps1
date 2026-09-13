#!/usr/bin/env pwsh
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArguments)

$ErrorActionPreference = 'Stop'
$request = $GhArguments -join ' '
if ($env:AI_LOOP_GH_LOG) { Add-Content -LiteralPath $env:AI_LOOP_GH_LOG -Value $request }
$fixturePath = $env:AI_LOOP_GH_FIXTURE
if ($fixturePath -and (Test-Path -LiteralPath $fixturePath)) {
    $fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -Depth 50
    foreach ($response in $fixture.responses) {
        if ($request -match $response.pattern) {
            if ($null -ne $response.output) {
                if ($request -match '^pr view\b' -and $env:AI_LOOP_GH_AFTER_MERGE_STATE -and
                    (Test-Path -LiteralPath $env:AI_LOOP_GH_LOG) -and
                    (@(Get-Content -LiteralPath $env:AI_LOOP_GH_LOG | Where-Object { $_ -match '^pr merge\b' }).Count -gt 0)) {
                    $response.output.state = 'MERGED'
                }
                if ($request -match '^api user\b' -and $response.output -is [string]) { Write-Output $response.output }
                else { Write-Output (ConvertTo-Json -InputObject $response.output -Depth 50 -Compress) }
            }
            exit ([int]$response.exitCode)
        }
    }
}

if ($request -match '^label (list|create|edit)\b') {
    if ($request -match '^label list\b') { Write-Output '[]' }
    exit 0
}
if ($request -match '^repo view\b') {
    Write-Output 'main'
    exit 0
}
if ($request -match '^auth status\b') { exit 0 }

# An unrecognised call is an error, so a changed GitHub API contract cannot turn
# a fail-closed test into a false positive or reach the user's live credentials.
[Console]::Error.WriteLine("Unexpected gh call: $request")
exit 78
