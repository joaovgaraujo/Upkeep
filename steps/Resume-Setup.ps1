param([Parameter(Mandatory)][string]$StatePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup-Resume.ps1')
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ($state.Status -ne 'WaitingForRestart') { exit 0 }
# Signing out and in is not a reboot. Keep waiting without changing anything.
if ($state.BootId -eq (Get-SetupBootId)) { exit 0 }
$root = Split-Path $PSScriptRoot -Parent
$state.Status = 'Running'
Save-SetupResumeState $StatePath $state
# One attempt per approval. Failures cannot create a login/reboot loop.
Unregister-ScheduledTask -TaskName $state.Task -Confirm:$false -ErrorAction Stop
try {
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $key) { throw 'Windows still has a pending restart. Automatic continuation stopped; review Windows Update and retry in Upkeep.' }
    }
    $failed = $false
    $remainingTweaks = @()
    $appReport = Join-Path $root 'resumed-apps.json'
    if ($state.Apps.Count) {
        $argsApps = @{ Apps=@($state.Apps); Catalog=(Join-Path $root 'apps.json'); NoRebootPrompt=$true; ResultFile=$appReport; PreferChoco=[bool]$state.PreferChoco }
        & (Join-Path $root 'Install-Apps.ps1') @argsApps
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    if ($state.Tweaks.Count) {
        $config = Join-Path $root 'resume-tweaks.json'
        ConvertTo-Json -InputObject @($state.Tweaks) | Set-Content -LiteralPath $config -Encoding UTF8
        & (Join-Path $root 'Setup-NewPC.ps1') -WinutilConfig $config -SkipDrivers -SkipApps -NoToggles -NoRebootPrompt -Resumed
        if ($LASTEXITCODE -eq 3010) { $remainingTweaks = @($state.Tweaks) }
        elseif ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    $state.Status = if ($failed) { 'NeedsAttention' } else { 'Completed' }
    $state.Detail = 'Continuation finished. See app/setup reports for results. Docker first-run terms and Linux user creation remain interactive.'
    Save-SetupResumeState $StatePath $state
    $results = @()
    if (Test-Path -LiteralPath $appReport) { $results = @((Get-Content -LiteralPath $appReport -Raw | ConvertFrom-Json)) }
    $pending = @(Get-RebootApps $results)
    if ($pending.Count -or $remainingTweaks.Count -or ($results | Where-Object { $_.ExitCode -eq 3010 })) {
        $state.Status = 'NeedsAnotherRestart'
        Save-SetupResumeState $StatePath $state
        Request-SetupResume -Root $root -Apps $pending -Tweaks $remainingTweaks -PreferChoco:$state.PreferChoco -RestartRequired
    }

} catch {
    $state.Status = 'NeedsAttention'
    $state.Detail = $_.Exception.Message
    Save-SetupResumeState $StatePath $state
    Write-Warning $state.Detail
} finally {
    $reports = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    Copy-Item -LiteralPath $StatePath -Destination (Join-Path $reports ($state.Task + '.json')) -Force
}
