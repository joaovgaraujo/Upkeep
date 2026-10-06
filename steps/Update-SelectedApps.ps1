$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE 'Documents\SystemUpdateLogs'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$log = Join-Path $dir ('Selected_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$code = 1
Start-Transcript -Path $log | Out-Null
try {
    & (Join-Path $PSScriptRoot 'Set-UpdateSafety.ps1')
    & (Join-Path $PSScriptRoot 'Update-WingetApps.ps1') -NoChocoFallback
    $code = $LASTEXITCODE
    & (Join-Path $PSScriptRoot 'Show-ManualUpdates.ps1') -Source winget
} catch { Write-Host "[error] $($_.Exception.Message)" }
finally {
    Write-Host '========================================'
    Write-Host '  Summary'
    $status = if ($code -eq 0) { 'ok' } elseif ($code -eq 3) { 'ok - some apps need a manual update (listed above)' } elseif ($code -eq 2) { 'skipped' } else { 'error - some selected apps remain pending; see details above' }
    Write-Host "  Winget: $status"
    foreach ($category in @('Topgrade','Windows Update','Store','Steam','JDownloader','EA App')) { Write-Host "  ${category}: skipped" }
    Write-Host "  Log: $log"
    Write-Host '========================================'
    Stop-Transcript | Out-Null
}
# 3 only means 'listed for a manual update', not a failure.
if ($code -eq 3) { $code = 0 }
exit $code
