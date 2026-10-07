<#
.SYNOPSIS
    Lists, at the end of a run, the apps that could not be updated
    automatically and what to do about each one.

.DESCRIPTION
    Steps write Reports\manual-updates-<source>.json (winget, choco, ai-cli, feature)
    for packages that are not failures of this run but cannot be updated
    unattended here: scope or installer-type mismatches, self-updating apps,
    programs in use. The engine deletes those files when a run starts, so
    anything present now belongs to this run. Printed BEFORE the summary
    block: the dashboard closes the engine shortly after the summary.
#>
[CmdletBinding()]
param(
    # Limit to these report sources (winget, choco, ai-cli, feature). Runs that only
    # touch winget pass 'winget' so an older run's other lists don't show.
    [string[]]$Source
)
$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
$items = @()
foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'manual-updates-*.json' -ErrorAction SilentlyContinue)) {
    if ($Source -and ($f.BaseName -replace '^manual-updates-') -notin $Source) { continue }
    try { $items += @(Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) } catch {}
}
if (-not $items.Count) { exit 0 }

Write-Host ''
Write-Host '----------------------------------------'
Write-Host "  Needs a manual update ($($items.Count)) - not errors, automatic updates can't handle these here:"
foreach ($i in $items) {
    $move = if ($i.Current -and $i.Available) { " $($i.Current) -> $($i.Available)" } else { '' }
    Write-Host "    - $($i.Name) [$($i.Id)]$move"
    Write-Host "        Why: $($i.Reason)"
    Write-Host "        Fix: $($i.Fix)"
}
Write-Host '----------------------------------------'
exit 0
