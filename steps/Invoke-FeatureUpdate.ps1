<#
.SYNOPSIS
    Moves Windows 11 24H2/25H2 up to version 26H2 (build 26300) and stops there.

.DESCRIPTION
    26H2 shares the 24H2/25H2 servicing branch, so it ships as an enablement
    package - a ~170 KB switch that flips already-staged binaries, not a
    reinstall. That makes it cheap enough to run inside an update pass, but it
    needs three things the normal Windows Update step does not do:

      1. A feature-update deferral blocks it. WinUtil's "security updates only"
         tweak writes DeferFeatureUpdates with a 365-day period, and while that
         is set Windows Update never offers 26H2 at all. The deferral is removed
         here, and every value touched is saved in the format
         Restore-SetupRegistry.ps1 reads, so the tweak can be put back.
      2. The enablement package refuses to install below a floor build
         (KB5124010, 2026-09-22). Under it, quality updates go in first, and
         that needs a restart before the enablement package can apply.
      3. KB5121794 is not published in the Microsoft Update Catalog. Windows
         Update is asked first, so a machine the rollout has reached takes the
         supported path; the .msu on Microsoft's delivery CDN is the fallback.

    Nothing here restarts the machine. Same rule as Invoke-WindowsUpdate.ps1
    (-IgnoreReboot) and topgrade's updates_auto_reboot="no": a restart under the
    user would kill every step queued behind this one. A pending restart is
    reported through the exit code and left to the dashboard.

    Every downloaded .msu is rejected unless Authenticode says it is validly
    signed by Microsoft - these are servicing payloads applied with SYSTEM
    rights, so a plausible-looking URL is not enough on its own.

.NOTES
    Exit code: 0 ok, 1 failed or timed out, 2 skipped / not applicable,
    3 ok but Windows must restart to finish.
#>
[CmdletBinding()]
param(
    [string]$LogFile,

    # 26H2. Parameters rather than literals so the next enablement package
    # needs new arguments instead of a new copy of this script.
    [ValidateRange(1, 99999)][int]$TargetBuild = 26300,
    [string]$TargetVersion = '26H2',
    [string]$EnablementKB = 'KB5121794',

    # Floor the enablement package enforces: KB5124010, 2026-09-22.
    [ValidateRange(0, 99999)][int]$PrerequisiteUbr = 9550,
    [string]$PrerequisiteKB = 'KB5124010',

    # Builds the enablement package applies to at all.
    [int[]]$SupportedBuilds = @(26100, 26200),

    [ValidateRange(1, 600)][int]$TimeoutMin = 90,
    [ValidateRange(1, 3600)][int]$HeartbeatSec = 300,

    # Pre-staged .msu, for an offline run or a package fetched by hand.
    [string]$EnablementMsuPath,

    # Microsoft's delivery CDN copy of the enablement package, per architecture.
    [hashtable]$EnablementMsuUrl = @{
        'AMD64' = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/94520a88-858f-4832-a57d-7211f6d84a4e/public/Windows11.0-KB5121794-x64_5e20a3cce48d6611b16bdec42b07167f5456586a.msu'
        'ARM64' = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/9d8dc3d0-9cbf-4eb1-9411-722e3e6a19b3/public/Windows11.0-KB5121794-arm64_77a76caf2d362bb293a4d18058388f2717365abe.msu'
    },

    [string]$PolicyBackupPath,

    # Leave the feature-update deferral in place. Windows Update then keeps
    # refusing 26H2, so this only makes sense with the .msu path.
    [switch]$KeepDeferralPolicy,

    # Report what would happen and change nothing.
    [switch]$DryRun,

    # Tests substitute their own bodies for the two long-running pieces.
    [scriptblock]$PrerequisiteJobBody,
    [scriptblock]$EnablementJobBody
)

. (Join-Path $PSScriptRoot 'Stream-Process.ps1')

$started = Get-Date
$deadline = $started.AddMinutes($TimeoutMin)

function Write-FeatureLine {
    param([AllowEmptyString()][string]$Line)
    Write-StepLine "[featureupdate] $Line" $LogFile
}

function Get-WindowsBuildInfo {
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Build          = [int]$key.CurrentBuild
        Ubr            = [int]$key.UBR
        DisplayVersion = "$($key.DisplayVersion)"
    }
}

function Test-RebootPending {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { return $true } }
    $false
}

# Writes entries in the shape Restore-SetupRegistry.ps1 reads, so undoing this
# is one documented command rather than a registry hunt.
function Save-PolicyBackup {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Entries)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ,$Entries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Clear-FeatureUpdateDeferral {
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (-not (Test-Path -LiteralPath $policyKey)) {
        Write-FeatureLine 'No Windows Update policy key is present.'
        return
    }

    # TargetReleaseVersion pins a machine to one release; left in place it
    # overrides everything else this step does.
    $names = @(
        'DeferFeatureUpdates'
        'DeferFeatureUpdatesPeriodInDays'
        'PauseFeatureUpdates'
        'PauseFeatureUpdatesStartTime'
        'TargetReleaseVersion'
        'TargetReleaseVersionInfo'
        'ProductVersion'
    )

    $key = Get-Item -LiteralPath $policyKey
    $present = @()
    foreach ($name in $names) {
        if ($key.GetValueNames() -notcontains $name) { continue }
        $value = $key.GetValue($name)
        # A pin that already names the target is doing no harm.
        if ($name -in @('TargetReleaseVersionInfo', 'ProductVersion') -and "$value" -eq $TargetVersion) { continue }
        $present += [pscustomobject]@{
            Path   = $policyKey
            Name   = $name
            Value  = $value
            Type   = $key.GetValueKind($name).ToString()
            Exists = $true
        }
    }

    if (-not $present.Count) {
        Write-FeatureLine 'No feature-update deferral is set.'
        return
    }

    $summary = ($present | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
    if ($DryRun) {
        Write-FeatureLine "[dry-run] would clear the feature-update deferral: $summary"
        return
    }

    Save-PolicyBackup -Path $PolicyBackupPath -Entries $present
    foreach ($entry in $present) {
        Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop
    }
    Write-FeatureLine "Cleared the feature-update deferral: $summary"
    Write-FeatureLine "Saved those values to $PolicyBackupPath"
    Write-FeatureLine "Put them back with: powershell -File `"$PSScriptRoot\Restore-SetupRegistry.ps1`" -Backup `"$PolicyBackupPath`""
}

# Streams a job's output, so a 40-minute servicing call still shows progress.
# Returns $true when the job finished without faulting.
function Invoke-StreamedJob {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [Parameter(Mandatory)][string]$What,
        [object[]]$ArgumentList = @()
    )
    $job = Start-Job -ScriptBlock $Body -ArgumentList $ArgumentList
    $lastOutput = Get-Date
    $ok = $true
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            $drained = $false
            foreach ($item in @(Receive-Job $job -ErrorAction SilentlyContinue)) {
                $text = "$item".TrimEnd()
                if ($text) { Write-FeatureLine $text; $drained = $true }
            }
            if ($drained) { $lastOutput = Get-Date }
            $now = Get-Date
            if ($now -ge $deadline) {
                Write-FeatureLine "[timeout] $What exceeded $TimeoutMin minutes - stopping."
                return $false
            }
            if (($now - $lastOutput).TotalSeconds -ge $HeartbeatSec) {
                Write-FeatureLine "$What still running ($(Format-Minutes ($now - $started)) elapsed)..."
                $lastOutput = $now
            }
            Start-Sleep -Seconds 2
        }
        foreach ($item in @(Receive-Job $job -ErrorAction SilentlyContinue)) {
            $text = "$item".TrimEnd()
            if ($text) { Write-FeatureLine $text }
        }
        if ($job.State -eq 'Failed') {
            $ok = $false
            foreach ($child in $job.ChildJobs) {
                foreach ($err in $child.Error) { Write-FeatureLine "[error] $($err.Exception.Message)" }
                if ($child.JobStateInfo.Reason) { Write-FeatureLine "[error] $($child.JobStateInfo.Reason.Message)" }
            }
        }
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    $ok
}

function Get-VerifiedMsu {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    Write-FeatureLine "Downloading $(Split-Path -Leaf $Destination)..."
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    } finally {
        $ProgressPreference = $progress
    }

    $size = (Get-Item -LiteralPath $Destination).Length
    if ($size -lt 50KB) { throw "The download is only $size bytes - that is not a servicing package." }

    # A .msu is applied with SYSTEM rights, so an unsigned or third-party-signed
    # file is never worth the risk, however plausible the URL looked.
    $signature = Get-AuthenticodeSignature -LiteralPath $Destination
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode reports '$($signature.Status)' for the package, not Valid."
    }
    $signer = "$($signature.SignerCertificate.Subject)"
    if ($signer -notmatch 'O=Microsoft Corporation') {
        throw "The package is signed by '$signer', which is not Microsoft."
    }
    Write-FeatureLine "Verified: $([math]::Round($size / 1KB)) KB, signed by Microsoft."
    $Destination
}

function Install-Msu {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$What)
    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    if ($remaining -lt 60) {
        Write-FeatureLine "[timeout] No time left in the $TimeoutMin-minute budget to install $What."
        return $false
    }
    # /NoRestart for the same reason the Windows Update step passes
    # -IgnoreReboot: this step does not get to restart the machine.
    $code = Invoke-StreamedProcess -FilePath "$env:SystemRoot\System32\dism.exe" `
        -Arguments "/Online /Add-Package /PackagePath:`"$Path`" /NoRestart /Quiet" `
        -Tag 'featureupdate' -LogFile $LogFile -TimeoutSec $remaining -HeartbeatSec $HeartbeatSec
    # 3010 is "applied, needs a restart", which is the expected result here.
    if ($code -in @(0, 3010)) { return $true }
    Write-FeatureLine "[error] DISM exited $code while installing $What."
    $false
}

# ---------------------------------------------------------------------------

if (-not $PolicyBackupPath) {
    $logDir = if ($LogFile) { Split-Path -Parent $LogFile } else { Join-Path $env:USERPROFILE 'Documents\SystemUpdateLogs' }
    $PolicyBackupPath = Join-Path $logDir "FeatureUpdate_PolicyBackup_$(Get-Date -Format yyyyMMdd_HHmmss).json"
}

$code = 0
try {
    $arch = "$env:PROCESSOR_ARCHITECTURE".ToUpperInvariant()
    $os = Get-WindowsBuildInfo
    Write-FeatureLine "Windows $($os.DisplayVersion), build $($os.Build).$($os.Ubr), $arch. Target: $TargetVersion (build $TargetBuild)."

    if ($os.Build -ge $TargetBuild) {
        Write-FeatureLine "Already on $($os.DisplayVersion) - nothing to upgrade."
        exit 2
    }
    if ($SupportedBuilds -notcontains $os.Build) {
        Write-FeatureLine "Build $($os.Build) is not on the $TargetVersion servicing branch ($($SupportedBuilds -join '/')), so the enablement package does not apply here. Reaching $TargetVersion from this build needs an in-place upgrade from installation media."
        exit 2
    }
    if (-not $EnablementMsuPath -and -not $EnablementMsuUrl.ContainsKey($arch)) {
        Write-FeatureLine "No $EnablementKB package is configured for $arch."
        exit 2
    }

    # An injected job body means the caller is driving this script in a test:
    # the real servicing calls are replaced, so there is nothing to elevate for.
    $underTest = $null -ne $PrerequisiteJobBody -or $null -ne $EnablementJobBody
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $DryRun -and -not $underTest) {
        throw 'Installing a feature update needs an elevated session.'
    }

    # Servicing calls fail in confusing ways while a restart is pending, and an
    # enablement package is the last thing worth gambling on that.
    if (Test-RebootPending) {
        Write-FeatureLine 'A restart is already pending from an earlier update. Restart Windows, then run the upgrade again.'
        exit 3
    }

    if ($KeepDeferralPolicy) {
        Write-FeatureLine 'Leaving the feature-update deferral in place (-KeepDeferralPolicy).'
    } else {
        Clear-FeatureUpdateDeferral
    }

    # --- Prerequisite cumulative update ---
    if ($os.Ubr -lt $PrerequisiteUbr) {
        Write-FeatureLine "$EnablementKB needs build $($os.Build).$PrerequisiteUbr or newer ($PrerequisiteKB); this machine is at .$($os.Ubr)."
        if ($DryRun) {
            Write-FeatureLine "[dry-run] would install cumulative updates, then $EnablementKB."
            exit 0
        }

        $body = $PrerequisiteJobBody
        if (-not $body) {
            $body = {
                Import-Module PSWindowsUpdate -ErrorAction Stop
                # Quality updates only: the enablement package is installed
                # deliberately further down, not swept up here.
                Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -NotCategory 'Upgrades' -ErrorAction Stop -Verbose *>&1 |
                    Out-String -Stream -Width 200
            }
        }
        if (-not (Invoke-StreamedJob -Body $body -What 'Prerequisite cumulative update')) {
            Write-FeatureLine '[warn] The prerequisite cumulative update did not complete - see the lines above.'
            exit 1
        }

        $os = Get-WindowsBuildInfo
        if ($os.Build -ge $TargetBuild) {
            Write-FeatureLine "Windows Update went straight to $($os.DisplayVersion)."
            exit 3
        }
        # The update is staged but not live until the restart, and its UBR only
        # appears afterwards, so the enablement package has to wait for it.
        if ($os.Ubr -lt $PrerequisiteUbr -or (Test-RebootPending)) {
            Write-FeatureLine "Prerequisite updates are staged (build is now $($os.Build).$($os.Ubr)). Restart Windows, then run the upgrade again to apply $EnablementKB."
            exit 3
        }
    }

    # --- Enablement package ---
    if ($DryRun) {
        Write-FeatureLine "[dry-run] would install $EnablementKB to reach $TargetVersion."
        exit 0
    }

    # Windows Update first: where the rollout has reached the machine, it
    # delivers the same package through the supported path.
    Write-FeatureLine "Asking Windows Update for $EnablementKB..."
    $wuBody = $EnablementJobBody
    if (-not $wuBody) {
        $wuBody = {
            param($KbId)
            Import-Module PSWindowsUpdate -ErrorAction Stop
            if (-not (Get-WindowsUpdate -MicrosoftUpdate -KBArticleID $KbId -ErrorAction Stop)) {
                'not-offered'
                return
            }
            Install-WindowsUpdate -MicrosoftUpdate -KBArticleID $KbId -AcceptAll -IgnoreReboot -ErrorAction Stop -Verbose *>&1 |
                Out-String -Stream -Width 200
        }
    }

    $offered = $false
    $wuJob = Start-Job -ScriptBlock $wuBody -ArgumentList $EnablementKB
    try {
        $wait = [int][math]::Max(60, ($deadline - (Get-Date)).TotalSeconds)
        $null = Wait-Job $wuJob -Timeout $wait
        $lines = @(Receive-Job $wuJob -ErrorAction SilentlyContinue | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ })
        foreach ($line in $lines) { if ($line -ne 'not-offered') { Write-FeatureLine $line } }
        $offered = $lines.Count -gt 0 -and $lines -notcontains 'not-offered' -and $wuJob.State -ne 'Failed'
    } finally {
        Stop-Job $wuJob -ErrorAction SilentlyContinue
        Remove-Job $wuJob -Force -ErrorAction SilentlyContinue
    }

    if (-not $offered) {
        Write-FeatureLine "Windows Update has not offered $EnablementKB yet (the rollout is gradual) - installing the package directly."
        $msu = $EnablementMsuPath
        if ($msu) {
            if (-not (Test-Path -LiteralPath $msu)) { throw "No .msu at $msu." }
            Write-FeatureLine "Using the supplied package: $msu"
        } else {
            $workDir = Join-Path $env:TEMP 'Upkeep-FeatureUpdate'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $msu = Get-VerifiedMsu -Url $EnablementMsuUrl[$arch] -Destination (Join-Path $workDir "Windows11.0-$EnablementKB-$arch.msu")
        }
        if (-not (Install-Msu -Path $msu -What $EnablementKB)) { exit 1 }
    }

    $os = Get-WindowsBuildInfo
    if ($os.Build -ge $TargetBuild) {
        Write-FeatureLine "Windows is now $($os.DisplayVersion) (build $($os.Build).$($os.Ubr))."
        exit 0
    }
    Write-FeatureLine "$EnablementKB is installed; the build stays $($os.Build) until Windows restarts."
    exit 3
} catch {
    Write-FeatureLine "[error] $($_.Exception.Message)"
    $code = 1
} finally {
    Write-FeatureLine "finished in $(Format-Minutes ((Get-Date) - $started)) ($(if ($code) { 'error' } else { 'ok' }))."
}

exit $code
