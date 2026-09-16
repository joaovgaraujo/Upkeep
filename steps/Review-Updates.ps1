param([ValidateSet('Preview','RetryUpdates','RetryApps')][string]$Mode = 'Preview')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Mode -eq 'Preview') {
    Write-Host 'Available WinGet application updates (no installation). Windows Update, Store and other tools are checked separately when run.'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warning 'WinGet is missing. New PC setup can prepare it.'; exit 2 }
    $p = Start-Process winget -ArgumentList @('upgrade','--include-unknown','--accept-source-agreements','--disable-interactivity') -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(180000)) { & taskkill /PID $p.Id /T /F | Out-Null; Write-Warning 'Inventory timed out. Check network and retry.'; exit 1 }
    $p.WaitForExit()
    if ($p.ExitCode -notin @(0,-1978335189,-1978335212)) { Write-Warning "Inventory failed: $($p.ExitCode)"; exit 1 }
} elseif ($Mode -eq 'RetryUpdates') {
    & (Join-Path $PSScriptRoot 'Set-UpdateSafety.ps1')
    & (Join-Path $PSScriptRoot 'Update-WingetApps.ps1') -RetryFailed
    exit $LASTEXITCODE
} else {
    $dir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
    $report = Get-ChildItem -LiteralPath $dir -Filter 'apps-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $report) { Write-Host 'No app installation report yet.'; exit 2 }
    & (Join-Path $root 'Install-Apps.ps1') -RetryReport $report.FullName
    exit $LASTEXITCODE
}
