<#
.SYNOPSIS
    Lets Logitech G HUB apply its own update, even when its updater service
    is disabled.

.DESCRIPTION
    G HUB updates through LGHUBUpdaterService: it downloads the next build to
    C:\ProgramData\LGHUB (described by next.json) and the service swaps it in.
    winget's Logitech.GHUB installer only starts that process and returns at
    once, so winget saw no version change and Upkeep called it an installer
    that does nothing (2026-10-24 to 11-03); the update landed half an hour
    later, after the run.

    On 2026-11-03 the service was set to Disabled to keep it out of startup.
    After that, nothing applied the staged builds: 2026.7.1011216 sat in
    next.json from 11-04. Starting the service for a minute applied it, with
    G HUB open, and the start type was put back to Disabled.

    This step does that on every run: start the service, wait until it has
    applied any staged build and finished checking, then restore the start
    type and running state exactly as they were. Startup settings are not
    changed. winget leaves Logitech.GHUB to this step.

.NOTES
    Exit codes: 0 = current or updated; 2 = G HUB not installed; 1 = error.
#>
[CmdletBinding()]
param(
    # 2 minutes: on this PC the service applied the build within seconds
    # with G HUB open; on the test laptop, with G HUB closed, it did not apply in 8
    # minutes or after a restart, and that wait held up the end of the run.
    [int]$TimeoutMin = 2,
    [string]$DataDir = 'C:\ProgramData\LGHUB',
    [string]$ServiceName = 'LGHUBUpdaterService'
)
$ErrorActionPreference = 'Continue'

function Get-BuildVersion {
    param([string]$File)
    $path = Join-Path $DataDir $File
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try { "$((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).version)" } catch { '' }
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host '[ghub] Logitech G HUB is not installed - skipping.'
    exit 2
}

$before = Get-BuildVersion 'current.json'
$staged = Get-BuildVersion 'next.json'
$origType = "$($svc.StartType)"
$origStatus = "$($svc.Status)"
$note = if ($staged -and $staged -ne $before) { ", $staged downloaded and waiting" } else { '' }
Write-Host "[ghub] G HUB $before$note; updater service is $origType/$origStatus."

$code = 0
try {
    if ($origType -eq 'Disabled') { Set-Service -Name $ServiceName -StartupType Manual -ErrorAction Stop }
    if ($origStatus -ne 'Running') { Start-Service -Name $ServiceName -ErrorAction Stop }

    # Done when the staged build is applied (next.json goes away or matches
    # current.json), or, with nothing staged, after a short check window in
    # which the service may find and stage a new build.
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $quietUntil = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $now = Get-BuildVersion 'current.json'
        $next = Get-BuildVersion 'next.json'
        if ($next -and $next -ne $now) { $quietUntil = (Get-Date).AddSeconds(60); continue }
        if ($now -ne $before) { break }
        if ((Get-Date) -gt $quietUntil) { break }
    }
    $after = Get-BuildVersion 'current.json'
    $pending = Get-BuildVersion 'next.json'
    if ($after -ne $before) {
        Write-Host "[ghub] Updated $before -> $after."
    } elseif ($pending -and $pending -ne $after) {
        Write-Host "[ghub] $pending is downloaded but was not applied in $TimeoutMin min; G HUB applies it the next time G HUB is opened."
    } else {
        Write-Host "[ghub] Already current ($after)."
    }
} catch {
    Write-Host "[ghub] Could not run G HUB's updater: $($_.Exception.Message)"
    $code = 1
} finally {
    # Put the service back as it was found.
    if ($origStatus -ne 'Running') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
    if ("$((Get-Service -Name $ServiceName).StartType)" -ne $origType) {
        Set-Service -Name $ServiceName -StartupType $origType -ErrorAction SilentlyContinue
    }
    $s = Get-Service -Name $ServiceName
    if ("$($s.StartType)" -ne $origType) {
        Write-Host "[ghub] Could not restore the updater service to $origType (it is $($s.StartType))."
        $code = 1
    }
}
exit $code
