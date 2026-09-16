# EA's uninstall/upgrade chain initiated an unsolicited reboot (System event
# 1074, 2026-09-16). Keep it out of BOTH package managers, including topgrade's
# Chocolatey pass. Failure to install either guard must stop the update run.
$ErrorActionPreference = 'Stop'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget list --id ElectronicArts.EADesktop --exact --accept-source-agreements --disable-interactivity | Out-Null
    $installed = $LASTEXITCODE
    if ($installed -notin @(0, -1978335212)) { throw "Could not check EA installation: winget exit $installed" }
    if ($installed -eq 0) {
    # --force replaces an existing non-blocking pin with a blocking pin.
    & winget pin add --id ElectronicArts.EADesktop --exact --blocking --force --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw 'Could not block unattended EA upgrades in winget.' }
    }
}
if (Get-Command choco -ErrorAction SilentlyContinue) {
    $packages = & choco list --exact ea-app --limit-output
    if ($LASTEXITCODE -ne 0) { throw 'Could not check EA installation in Chocolatey.' }
    if ($packages -match '^ea-app\|') {
    & choco pin add --name=ea-app
    if ($LASTEXITCODE -ne 0) { throw 'Could not block unattended EA upgrades in Chocolatey.' }
    }
}
Write-Host '[safety] EA automatic upgrades, launch and repair are disabled: its installer can restart Windows. Update EA manually when ready.'
