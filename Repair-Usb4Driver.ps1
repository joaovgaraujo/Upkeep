<#
.SYNOPSIS
    Undoes a wrong Intel Thunderbolt driver on USB4 controllers that Windows
    manages itself.

.DESCRIPTION
    On newer Intel laptops (e.g. 13th gen+ with USB4) the controller exposes
    the compatible ID PCI\USB4_MS_CM, meaning Windows' inbox USB4 connection
    manager (usb4hostrouter.inf) is supposed to drive it. Driver updaters such
    as SDIO rank Intel's standalone "tbthostcontroller" package higher and
    install it anyway; the controller then fails to start (Code 10,
    "Timed out waiting for CM") and the USB4/Thunderbolt port is dead.

    This script finds such controllers, exports every Intel tbt* driver package
    to a backup folder, removes them and rescans, so the inbox driver binds.
    It changes nothing when no USB4_MS_CM controller uses an Intel tbt driver.

    Exit codes: 0 = nothing to do or fixed, 1 = error, 3010 = fixed, restart
    recommended (the USB4 root router usually only starts after one).

.PARAMETER BackupDir
    Where removed driver packages are exported. Default: Logs\usb4-driver-backup
    next to this script. Restore with:
    pnputil /add-driver "<BackupDir>\*.inf" /subdirs /install

.PARAMETER DryRun
    Report what would be removed without changing anything.
#>

[CmdletBinding()]
param(
    [string]$BackupDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $BackupDir) {
    $BackupDir = Join-Path $PSScriptRoot (Join-Path 'Logs' 'usb4-driver-backup')
}

# Controllers meant for the inbox USB4 stack but bound to something else.
$wrong = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object {
        $_.DeviceID -match 'USB4_MS_CM' -and $_.InfName -and $_.InfName -ne 'usb4hostrouter.inf' -and
        $_.DriverProviderName -notmatch '^Microsoft'
    })

if ($wrong.Count -eq 0) {
    Write-Output "[usb4] OK -- no USB4 controller is using a non-inbox Thunderbolt driver."
    exit 0
}

foreach ($dev in $wrong) {
    Write-Output "[usb4] $($dev.DeviceName) uses $($dev.InfName) ($($dev.DriverProviderName) $($dev.DriverVersion)) instead of the Windows USB4 driver."
}

# Every Intel Thunderbolt package, not only the bound one: the companion
# components (tbthostcontroller*component, tbtp2pndisdrv) are useless without
# it and would pull the controller driver back in.
$packages = New-Object System.Collections.Generic.List[object]
$current = @{}
foreach ($line in (pnputil /enum-drivers)) {
    if ($line -match '^\s*Published Name:\s*(\S+)') { $current = @{ Published = $Matches[1] } }
    elseif ($line -match '^\s*Original Name:\s*(\S+)') {
        $current.Original = $Matches[1]
        if ($current.Original -match '^tbt.*\.inf$') { $packages.Add([pscustomobject]$current) }
    }
}

if ($DryRun) {
    foreach ($p in $packages) { Write-Output "[usb4] [dry-run] Would back up and remove $($p.Published) ($($p.Original))" }
    exit 0
}

try {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    foreach ($p in $packages) {
        & pnputil /export-driver $p.Published $BackupDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "export of $($p.Published) failed (exit $LASTEXITCODE)" }
    }
    foreach ($p in $packages) {
        & pnputil /delete-driver $p.Published /uninstall | Out-Null
        Write-Output "[usb4] Removed $($p.Published) ($($p.Original)), exit $LASTEXITCODE"
    }
    & pnputil /scan-devices | Out-Null
} catch {
    Write-Output "[usb4] ERROR: $($_.Exception.Message) -- nothing further removed."
    exit 1
}

Start-Sleep -Seconds 5
$host_ = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -match 'USB4_MS_CM' } | Select-Object -First 1
Write-Output "[usb4] Controller driver now: $($host_.InfName) ($($host_.DriverProviderName)). Backup: $BackupDir"
Write-Output "[usb4] Restart Windows so the USB4 root router starts."
exit 3010
