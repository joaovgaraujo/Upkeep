# Update-StoreApps.ps1
# Triggers Microsoft Store app updates and WAITS for completion, unlike the old
# fire-and-forget MDM UpdateScanMethod call. Three mechanisms, in order:
#   1. MDM UpdateScanMethod - kicks the Store's own background updater (broad,
#      needs elevation; "Access denied" unelevated).
#   2. WinRT AppInstallManager.SearchForAllUpdatesAsync - the API the Store
#      itself uses to enumerate pending updates. Needs the packageManagement
#      restricted capability, so it can fail with E_ACCESSDENIED; when it does
#      we fall back to (3).
#   3. WinRT AppInstallManager.UpdateAppByPackageFamilyNameAsync per installed
#      package - slower and noisier, but works without that capability.
# Requires Windows PowerShell 5.1 (WinRT projections do not load in pwsh 7).
# Output lines are prefixed [store] for the dashboard's category parser.
# Exit codes: 0 = all ok (or nothing to update), 1 = one or more apps failed.
#
# NOTE ON "NOTHING HAPPENED": an earlier version of this script swallowed
# per-package exceptions into an empty catch block, so "no updates available"
# and "every single call failed" printed the exact same thing - a bare
# "Updated: 0". Every path below is now counted and reported; if this step
# does nothing, the summary says *why*.

[CmdletBinding()]
param(
    # Ceiling for one WinRT call (the search, or queueing one package).
    [int]$PerAppTimeoutSec = 300,

    # How long to wait for the queued updates, all of them together.
    [int]$WaitMin = 10,

    # Stop waiting once no queued update has changed state for this long:
    # items parked at "Pending 0%" behind an open app do not move on their own.
    [int]$IdleStopSec = 180,

    # Overall ceiling for the whole step.
    [int]$TotalTimeoutMin = 25
)

$ErrorActionPreference = 'Continue'
$deadline = (Get-Date).AddMinutes($TotalTimeoutMin)

$failed = 0
$updated = 0
$notServiced = 0   # package exists but the Store won't service it
$noUpdate = 0      # package is up to date
$stillRunning = 0  # hit the per-app timeout, still downloading in background
$script:inUse = @()  # open apps the Store could not replace (0x80073D02)
$errorCodes = @{}  # HRESULT -> count, so odd failures are visible in the log

function Add-ErrorCode {
    param($Exception)
    $inner = $Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    $code = '0x{0:X8}' -f $inner.HResult
    $errorCodes[$code] = 1 + ($errorCodes[$code] | ForEach-Object { $_ })
    return $code
}

Write-Host '[store] Triggering Microsoft Store update scan (MDM)...'
try {
    Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' `
        -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
        Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
    Write-Host '[store] MDM scan triggered.'
}
catch {
    # Unelevated this is always "Access denied". Not fatal: the WinRT paths
    # below do the actual work.
    Write-Host "[store] MDM scan unavailable: $($_.Exception.Message.Trim())"
}

# --- WinRT async -> .NET Task bridge (required to await IAsyncOperation in PS) ---
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

    [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime] | Out-Null
    $mgr = New-Object Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager
}
catch {
    Write-Host "[store] WinRT AppInstallManager unavailable: $($_.Exception.Message)"
    Write-Host '[store] Store apps will still update in the background via the MDM scan.'
    exit 0
}

function Await-WinRT {
    param($WinRtTask, $ResultType)
    $netTask = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
    # Bounded, not Wait(-1): the deadline checks in the loops below only fire
    # between packages, so a single WinRT call that never completes used to
    # wedge the whole step past -TotalTimeoutMin with no way out.
    if (-not $netTask.Wait($PerAppTimeoutSec * 1000)) {
        throw [System.TimeoutException]::new(
            "WinRT call did not complete within $PerAppTimeoutSec seconds.")
    }
    $netTask.Result
}

$itemType = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem]

# Installed version per package family, so "updated" means the version moved.
# The Store's own status is not enough: on 2026-11-03 eight apps read
# "completed" while five of them (WhatsApp, the Store itself, GamingApp,
# RawImageExtension, WinAppRuntime) stayed on the old version, and the next
# run offered the same updates again.
function Get-InstalledVersions {
    $map = @{}
    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        $v = "$($p.Version)"
        if (-not $map.ContainsKey($p.PackageFamilyName) -or [version]$v -gt [version]$map[$p.PackageFamilyName]) {
            $map[$p.PackageFamilyName] = $v
        }
    }
    $map
}

# Names the processes running from a package family's install folder, or ''.
# The Store holds an update back while its app is open (WhatsApp sat at
# "Paused", and the rest of the queue at "Pending 0%" behind it).
function Get-RunningFromPackage {
    param([string]$FamilyName)
    $name = ($FamilyName -split '_')[0]
    $hits = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path -like "*\WindowsApps\$($name)_*" })
    (@($hits | Select-Object -ExpandProperty ProcessName -Unique) | ForEach-Object { "$_.exe" }) -join ', '
}

# Waits for ALL queued items at once. The Store works through its queue on
# its own, but the old loop waited up to $PerAppTimeoutSec for each item in
# turn, so five stuck items cost 25 minutes (2026-10-28) and the Store lane
# became the slowest part of the run. Stops when every item is done, when
# nothing has changed for $IdleStopSec, or after $WaitMin minutes.
# Returns PackageFamilyName -> 'done', 'failed', 'skipped', 'inuse', 'canceled' or 'waiting'.
function Wait-ForInstallItems {
    param([object[]]$Items)

    $state = [ordered]@{}
    $last = @{}
    foreach ($i in $Items) {
        if ($state.Contains($i.PackageFamilyName)) { continue }
        $state[$i.PackageFamilyName] = 'waiting'
        $last[$i.PackageFamilyName] = ''
    }
    $waitUntil = (Get-Date).AddMinutes($WaitMin)
    if ($waitUntil -gt $deadline) { $waitUntil = $deadline }
    $lastChange = Get-Date

    while ($true) {
        $open = 0
        foreach ($i in $Items) {
            $pfn = $i.PackageFamilyName
            if ($state[$pfn] -ne 'waiting') { continue }
            try { $st = $i.GetCurrentStatus() } catch { continue }
            $now = "$($st.InstallState) $($st.PercentComplete)%"
            if ($now -ne $last[$pfn]) {
                Write-Host "[store]   $($pfn): $now"
                $last[$pfn] = $now
                $lastChange = Get-Date
            }
            if ("$($st.InstallState)" -eq 'Completed') { $state[$pfn] = 'done'; continue }
            if ("$($st.InstallState)" -in @('Error', 'Canceled')) {
                $errText = "$($st.ErrorCode)"
                if ("$($st.InstallState)" -eq 'Canceled') {
                    # The Store aborts an item itself (E_ABORT) when it
                    # re-queues or supersedes it; Photos did this at "100%",
                    # which the old check counted as installed. Not ours to
                    # fail; the version check below says whether it landed.
                    $state[$pfn] = 'canceled'
                } elseif ($errText -match '0x80073CFB') {
                    # Same package identity installed through another channel
                    # (winget/MSI - e.g. WSL) - the Store can't overlay it.
                    Write-Host "[store]   $($pfn): managed outside the Store (winget/MSI) - skipped."
                    $state[$pfn] = 'skipped'
                } elseif ($errText -match '0x80073D02') {
                    # "Resources it modifies are currently in use": the app is open.
                    $state[$pfn] = 'inuse'
                } else {
                    Write-Host "[store]   $($pfn): failed ($($st.InstallState) $errText)."
                    $state[$pfn] = 'failed'
                }
                continue
            }
            $open++
        }
        if ($open -eq 0) { break }
        if ((Get-Date) -gt $waitUntil) {
            Write-Host "[store] Stopped waiting after $WaitMin min; $open app(s) stay queued in the Store."
            break
        }
        if (((Get-Date) - $lastChange).TotalSeconds -gt $IdleStopSec) {
            Write-Host "[store] No progress for $IdleStopSec s; $open app(s) stay queued in the Store."
            break
        }
        Start-Sleep -Seconds 3
    }
    $state
}

$versionsBefore = Get-InstalledVersions
$queued = @()

# --- Path 2: ask the Store for everything that has an update ---------------
# $searchWorked is set only after the list came back, so a throw still runs
# the per-package fallback below.
$searchWorked = $false
try {
    $listType = [System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem]]
    $pending = Await-WinRT $mgr.SearchForAllUpdatesAsync() $listType
    $queued = @($pending)
    Write-Host "[store] Store reports $($queued.Count) app(s) with updates available."
    $searchWorked = $true
}
catch {
    $code = Add-ErrorCode $_.Exception
    if ($code -eq '0x80070005') {
        # E_ACCESSDENIED: SearchForAllUpdatesAsync needs the packageManagement
        # restricted capability, which a plain PowerShell host doesn't hold.
        Write-Host '[store] Bulk update search denied (needs packageManagement capability) - falling back to a per-package check.'
    }
    else {
        Write-Host "[store] Bulk update search failed ($code) - falling back to a per-package check."
    }
}

# --- Path 3: per-package fallback -----------------------------------------
if (-not $searchWorked) {
    # Skip frameworks and system-locked packages; those update through servicing.
    $targets = Get-AppxPackage | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable }
    Write-Host "[store] Checking $($targets.Count) installed packages for updates..."

    foreach ($pkg in $targets) {
        if ((Get-Date) -gt $deadline) {
            Write-Host "[store] Total time budget of $TotalTimeoutMin minutes exhausted - remaining apps update in background."
            break
        }
        try {
            $op = $mgr.UpdateAppByPackageFamilyNameAsync($pkg.PackageFamilyName)
            $item = Await-WinRT $op $itemType
            if ($null -eq $item) { $noUpdate++; continue }
            $queued += $item
        }
        catch {
            # 0x803FB112 and friends mean "this package isn't serviced by the
            # Store" (sideloaded, dev-installed, delisted, or installed through
            # another channel). Counted rather than silently dropped so the
            # summary can explain a quiet run.
            $code = Add-ErrorCode $_.Exception
            $notServiced++
            Write-Verbose "[store]   $($pkg.Name): not serviced by the Store ($code)."
        }
    }
}

if ($queued.Count -gt 0) {
    Write-Host "[store] Waiting for $($queued.Count) Store update(s) together (up to $WaitMin min)..."
    $result = Wait-ForInstallItems -Items $queued
    # A moment for the Store to register the last finished packages.
    Start-Sleep -Seconds 5
    $versionsAfter = Get-InstalledVersions
    foreach ($pfn in @($result.Keys)) {
        $was = $versionsBefore[$pfn]; $now = $versionsAfter[$pfn]
        if ($now -and $was -ne $now) {
            Write-Host "[store]   $($pfn): updated $was -> $now."
            $updated++
            continue
        }
        if ($result[$pfn] -eq 'failed') { $failed++; continue }
        if ($result[$pfn] -eq 'skipped') { $notServiced++; continue }
        $running = Get-RunningFromPackage -FamilyName $pfn
        if ($running -or $result[$pfn] -eq 'inuse') {
            $who = if ($running) { " ($running)" } else { '' }
            Write-Host "[store]   $($pfn): the app is open$who, so the Store cannot replace it - listed at the end."
            $script:inUse += $pfn
        } elseif ($result[$pfn] -eq 'canceled') {
            Write-Host "[store]   $($pfn): the Store canceled this update itself, version unchanged - it retries on its own."
            $stillRunning++
        } else {
            Write-Host "[store]   $($pfn): still queued in the Store, version unchanged - it finishes in the background or after a restart."
            $stillRunning++
        }
    }
}

# --- Summary ---------------------------------------------------------------
$parts = @("updated: $updated", "failed: $failed", "not serviced by the Store: $notServiced")
if ($stillRunning -gt 0) { $parts += "still queued in the Store: $stillRunning" }
if ($script:inUse.Count -gt 0) { $parts += "open, listed for a manual update: $($script:inUse.Count)" }
if (-not $searchWorked) { $parts += "already current: $noUpdate" }
Write-Host "[store] Done. $($parts -join ', ')."

if ($errorCodes.Count -gt 0) {
    $summary = ($errorCodes.GetEnumerator() | Sort-Object Value -Descending |
        ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', '
    Write-Host "[store] Non-fatal API results seen: $summary"
}
if ($updated -eq 0 -and $failed -eq 0 -and $stillRunning -eq 0 -and $script:inUse.Count -eq 0) {
    Write-Host '[store] No Store apps needed updating this run.'
}

if ($script:inUse.Count -gt 0) {
    $dir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    ConvertTo-Json -Depth 3 -InputObject @($script:inUse | ForEach-Object {
            [pscustomobject]@{ Source = 'store'; Id = $_; Name = ($_ -replace '_[a-z0-9]{13}$', '')
                Reason = 'the app was open, so the Store could not replace its files'
                Fix = 'Close the app; the Store finishes the update in the background, or run Upkeep again.' }
        }) | Set-Content -LiteralPath (Join-Path $dir 'manual-updates-store.json') -Encoding UTF8
}

if ($failed -gt 0) { exit 1 } else { exit 0 }
