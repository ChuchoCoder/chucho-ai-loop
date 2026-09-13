#!/usr/bin/env pwsh
$GitArguments = @($args)

$lsRemoteIndex = [array]::IndexOf($GitArguments, 'ls-remote')
if ($lsRemoteIndex -ge 0) {
    $root = if ($GitArguments.Length -ge 2 -and $GitArguments[0] -eq '-C') { $GitArguments[1] } else { (Get-Location).Path }
    $sha = & $env:AI_LOOP_REAL_GIT -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $reference = $GitArguments[-1]
    Write-Output "$sha`t$reference"
    exit 0
}
& $env:AI_LOOP_REAL_GIT @GitArguments
exit $LASTEXITCODE
