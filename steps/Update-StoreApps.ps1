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
    # Per-app ceiling; a stuck download shouldn't wedge the whole run.
    [int]$PerAppTimeoutSec = 300,

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

# Waits for one AppInstallItem to finish, reporting progress. Returns
# 'updated', 'failed', 'skipped' or 'running'.
function Wait-ForInstallItem {
    param($Item, [string]$Label)

    Write-Host "[store] Updating $Label..."
    $appDeadline = (Get-Date).AddSeconds($PerAppTimeoutSec)
    $lastPct = -1

    while ($true) {
        $st = $Item.GetCurrentStatus()

        if ($st.InstallState -eq 'Completed' -or $st.PercentComplete -eq 100) {
            Write-Host "[store]   $($Label): completed."
            return 'updated'
        }
        if ($st.InstallState -in @('Error', 'Canceled')) {
            $errText = "$($st.ErrorCode)"
            if ($errText -match '0x80073CFB') {
                # Same package identity installed through another channel
                # (winget/MSI - e.g. WSL) - the Store can't overlay it.
                # Not a failure; that install updates via its own manager.
                Write-Host "[store]   $($Label): managed outside the Store (winget/MSI) - skipped."
                return 'skipped'
            }
            Write-Host "[store]   $($Label): failed ($($st.InstallState) $errText)."
            return 'failed'
        }
        if ((Get-Date) -gt $appDeadline) {
            Write-Host "[store]   $($Label): still installing after ${PerAppTimeoutSec}s - leaving it running in background."
            return 'running'
        }

        if ($st.PercentComplete -ne $lastPct) {
            Write-Host "[store]   $($Label): $($st.PercentComplete)%"
            $lastPct = $st.PercentComplete
        }
        Start-Sleep -Seconds 3
    }
}

# --- Path 2: ask the Store for everything that has an update ---------------
# $searchWorked means "the bulk search returned a list", and is set ONLY
# after the whole list has been walked. Setting it as soon as the call
# returned meant a throw partway through the loop printed "falling back to a
# per-package check" while the fallback below was skipped, so the remaining
# apps were never checked by either path.
$searchWorked = $false
try {
    $listType = [System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem]]
    $pending = Await-WinRT $mgr.SearchForAllUpdatesAsync() $listType

    $count = @($pending).Count
    Write-Host "[store] Store reports $count app(s) with updates available."
    foreach ($item in $pending) {
        if ((Get-Date) -gt $deadline) {
            Write-Host "[store] Total time budget of $TotalTimeoutMin minutes exhausted - remaining apps update in background."
            break
        }
        switch (Wait-ForInstallItem -Item $item -Label $item.PackageFamilyName) {
            'updated' { $updated++ }
            'failed'  { $failed++ }
            'skipped' { $notServiced++ }
            'running' { $stillRunning++ }
        }
    }
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

            switch (Wait-ForInstallItem -Item $item -Label $pkg.Name) {
                'updated' { $updated++ }
                'failed'  { $failed++ }
                'skipped' { $notServiced++ }
                'running' { $stillRunning++ }
            }
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

# --- Summary ---------------------------------------------------------------
$parts = @("updated: $updated", "failed: $failed", "not serviced by the Store: $notServiced")
if ($stillRunning -gt 0) { $parts += "still downloading in background: $stillRunning" }
if (-not $searchWorked) { $parts += "already current: $noUpdate" }
Write-Host "[store] Done. $($parts -join ', ')."

if ($errorCodes.Count -gt 0) {
    $summary = ($errorCodes.GetEnumerator() | Sort-Object Value -Descending |
        ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', '
    Write-Host "[store] Non-fatal API results seen: $summary"
}
if ($updated -eq 0 -and $failed -eq 0 -and $stillRunning -eq 0) {
    Write-Host '[store] No Store apps needed updating this run.'
}

if ($failed -gt 0) { exit 1 } else { exit 0 }
