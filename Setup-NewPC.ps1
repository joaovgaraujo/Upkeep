<#
.SYNOPSIS
    One-shot basic setup for a fresh Windows installation: restore point,
    curated winutil tweaks + junk-app removal, quality-of-life registry
    toggles, drivers (SDIO, plus NVCleanstall package for NVIDIA GPUs) and
    the essentials app pack.

.DESCRIPTION
    Orchestrates the phases below in order. Each phase can be skipped, and
    records results and backups. Restart continuation requires user approval.

      1. Restore point   (safety net)
      2. Windows tweaks  (winutil -Config presets\winutil-newpc.json, headless)
      3. Toggles         (registry: dark theme, file extensions, mouse
                          acceleration off, num lock, sticky keys off, ...)
      4. Drivers         (SDIO -autoinstall; NVCleanstall prebuilt package
                          when an NVIDIA GPU is present and the package
                          exists -- see NVCleanPackagePath in settings.json)
      5. Apps            (Install-Apps.ps1 -Preset <AppsPreset>)

    Tool paths and the winutil bootstrap command are read from settings.json
    next to this script (same file the dashboard uses).

.PARAMETER Toggles
    Comma-separated toggle slugs to apply. Default: a sensible set for a
    non-technical user. Available slugs:
      dark-theme, file-extensions, hidden-files, mouse-accel-off, num-lock,
      sticky-keys-off, verbose-bsod, long-paths

.PARAMETER AppsPreset
    Preset under presets/ for the app install phase. Default: new-pc-basic.

.PARAMETER WinutilConfig
    winutil config JSON (exported selection format). Default:
    presets\winutil-newpc.json next to this script.

.EXAMPLE
    powershell -NoProfile -File .\Setup-NewPC.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -File .\Setup-NewPC.ps1 -SkipDrivers -Toggles dark-theme,mouse-accel-off
#>

[CmdletBinding()]
param(
    [switch]$SkipRestorePoint,
    [switch]$SkipTweaks,
    [switch]$SkipDrivers,
    [switch]$InstallDrivers,
    [switch]$SkipApps,
    [switch]$NoToggles,
    [switch]$NoRebootPrompt,

    [Parameter()]
    [string[]]$Toggles = @('file-extensions', 'long-paths'),

    # O&O ShutUp10++. Mode 'auto' (default) applies a config silently with
    # /quiet: your exported config (settings.json key OOSUConfigPath) if set,
    # else the bundled presets\ooshutup10-recommended.cfg (O&O's own
    # "Recommended" preset). Mode 'manual' downloads and opens the GUI so the
    # user can hit "Actions > Apply only recommended settings" themselves.
    [switch]$Oosu,

    [ValidateSet('auto', 'manual')]
    [string]$OosuMode = 'auto',

    [Parameter()]
    [string]$AppsPreset = 'new-pc-basic',

    [Parameter()]
    [string]$WinutilConfig,

    # Run even when Windows reports a pending restart. By default the script
    # defers servicing until a manual restart and rerun: servicing
    # (DISM) calls made by winutil tweaks queue forever until that restart.
    [switch]$IgnorePendingReboot,

    # Set by the one-shot resume task; prevents re-scheduling in a loop when
    # a restart did not clear the pending state.
    [switch]$Resumed,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $InstallDrivers) { $SkipDrivers = $true }
if ($NoToggles) { $Toggles = @() }

# $PSScriptRoot is not reliably populated during param default evaluation in
# Windows PowerShell 5.1, so resolve path defaults in the body (see
# Install-Apps.ps1 for the same gotcha).
if (-not $WinutilConfig) {
    $WinutilConfig = Join-Path $PSScriptRoot (Join-Path 'presets' 'winutil-newpc.json')
}

# With `powershell -File`, "a,b,c" binds as ONE string[] element; normalize.
if ($Toggles) {
    $Toggles = @($Toggles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Self-elevate (UAC prompt) if not already elevated.
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Command line that re-runs this script with the same selection. Shared by
# self-elevation and the resume-after-restart task. -Toggles is always passed
# (possibly empty) so "no toggles" is not replaced by the default set.
function Get-RelaunchArgs {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")

    if ($SkipRestorePoint)    { $argList += '-SkipRestorePoint' }
    if ($SkipTweaks)          { $argList += '-SkipTweaks' }
    if ($SkipDrivers)         { $argList += '-SkipDrivers' }
    if ($InstallDrivers)      { $argList += '-InstallDrivers' }
    if ($SkipApps)            { $argList += '-SkipApps' }
    if ($NoRebootPrompt)      { $argList += '-NoRebootPrompt' }
    if ($Oosu)                { $argList += @('-Oosu', '-OosuMode', $OosuMode) }
    if ($Toggles.Count) { $argList += @('-Toggles', "`"$($Toggles -join ',')`"") } else { $argList += '-NoToggles' }
    if ($AppsPreset)          { $argList += @('-AppsPreset', "`"$AppsPreset`"") }
    if ($WinutilConfig)       { $argList += @('-WinutilConfig', "`"$WinutilConfig`"") }
    if ($IgnorePendingReboot) { $argList += '-IgnorePendingReboot' }
    return $argList
}

if ($DryRun) {
    if (-not (Test-IsAdmin)) {
        Write-Output "Not running as administrator -- continuing anyway because -DryRun makes no changes."
    }
} elseif (-not (Test-IsAdmin)) {
    Write-Output "Not running as administrator. Requesting elevation..."

    $argList = Get-RelaunchArgs
    if ($Resumed) { $argList += '-Resumed' }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -ErrorAction Stop
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        Write-Output ""
        Write-Output "Elevation was declined or failed. Setup requires administrator rights."
        Write-Output "Nothing was changed."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# settings.json (same file the dashboard reads/writes)
# ---------------------------------------------------------------------------
$settings = $null
$settingsPath = Join-Path $PSScriptRoot 'settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } catch {
        Write-Output "[setup] WARNING: settings.json could not be parsed; using defaults. ($($_.Exception.Message))"
    }
}

function Get-SettingString {
    param([string]$Name, [string]$Default = '')
    if ($settings -and $settings.PSObject.Properties[$Name] -and $settings.$Name) {
        return [string]$settings.$Name
    }
    return $Default
}

# ---------------------------------------------------------------------------
# Phase result tracking
# ---------------------------------------------------------------------------
$reportDir = Join-Path $env:LOCALAPPDATA ('Upkeep\Reports\setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
Write-Output "Setup reports and backups: $reportDir"
try { Start-Transcript -Path (Join-Path $reportDir 'setup.log') -ErrorAction Stop | Out-Null } catch { Write-Warning "Transcript unavailable: $_" }
$registryBackup = New-Object System.Collections.Generic.List[object]
$deferredIds = @()
$setupAppReport = Join-Path $reportDir 'apps.json'
$phaseResults = New-Object System.Collections.Generic.List[object]

function Add-PhaseResult {
    param([string]$Phase, [string]$Status, [string]$Detail = '')
    $phaseResults.Add([pscustomobject]@{ Phase = $Phase; Status = $Status; Detail = $Detail })
    ConvertTo-Json -InputObject @($phaseResults.ToArray()) -Depth 6 | Set-Content -LiteralPath (Join-Path $reportDir 'results.json') -Encoding UTF8
}

<#
.SYNOPSIS
    Removes duplicate entries from the hosts file, keeping the first of each.

.DESCRIPTION
    Only ever DELETES lines that are an exact repeat of an earlier mapping, so
    the surviving file resolves identically to the one it replaces -- the
    resolver already used the first match, and that is the one kept.

    Comment lines and blank lines are passed through untouched, so section
    markers and hand-written notes survive. Comparison is on the normalized
    "<ip> <host>" pair (case-insensitive, whitespace collapsed) rather than the
    raw line, so the same mapping written with different spacing still counts
    as a duplicate. A trailing comment makes a line distinct and it is kept:
    dropping it could lose the only note explaining why an entry exists.

    A copy of the original is written next to the file before anything changes.
#>
function Repair-HostsFile {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hosts)) { return }

    try {
        $lines = @(Get-Content -LiteralPath $hosts -ErrorAction Stop)
    } catch {
        Write-Output "[hosts] WARNING: could not read the hosts file: $($_.Exception.Message)"
        return
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = 0

    foreach ($line in $lines) {
        # Comments, blanks and anything that isn't a plain "<ip> <host...>"
        # mapping pass through untouched.
        if ($line -match '^\s*(#|$)') { $kept.Add($line); continue }
        if ($line -match '#') { $kept.Add($line); continue }

        $key = ($line.Trim() -replace '\s+', ' ')
        if ($key -notmatch '^\S+\s+\S+') { $kept.Add($line); continue }

        if ($seen.Add($key)) { $kept.Add($line) } else { $removed++ }
    }

    if ($removed -eq 0) {
        Write-Output '[hosts] No duplicate entries.'
        return
    }

    if ($DryRun) {
        Write-Output "[hosts] [dry-run] Would remove $removed duplicate entry/entries from the hosts file."
        return
    }

    # Write a complete replacement FIRST, check it, and only then swap it in.
    # Writing over the live file directly is not survivable: Set-Content
    # truncates before it writes, so a write that fails part way leaves the
    # machine with an empty hosts file. That is not hypothetical -- Defender
    # guards this specific file and can reject the write after the truncate,
    # which empties it ("Stream was not readable"). A temp-then-replace keeps
    # the original intact no matter where the failure lands.
    $backup = "$hosts.upkeep-bak"
    $tmp = "$hosts.upkeep-tmp"
    try {
        Copy-Item -LiteralPath $hosts -Destination $backup -Force -ErrorAction Stop

        # ASCII, no BOM: the resolver does not treat a UTF-8 BOM as whitespace,
        # so the first entry after one is silently ignored.
        Set-Content -LiteralPath $tmp -Value $kept -Encoding ASCII -ErrorAction Stop

        # Refuse to install a replacement that lost content. Catches a
        # truncated or partially flushed write before it reaches the real file.
        $check = @(Get-Content -LiteralPath $tmp -ErrorAction Stop)
        if ($check.Count -ne $kept.Count) {
            throw "staged file has $($check.Count) lines, expected $($kept.Count)"
        }

        Move-Item -LiteralPath $tmp -Destination $hosts -Force -ErrorAction Stop
        Write-Output "[hosts] Removed $removed duplicate entry/entries (backup: $backup)."
        ipconfig /flushdns | Out-Null
    } catch {
        Write-Output "[hosts] WARNING: could not rewrite the hosts file: $($_.Exception.Message)"
        Write-Output "[hosts] The hosts file was left unchanged."
        # A failed Move leaves the original in place; only the staging file
        # needs clearing. Security software commonly blocks writes here.
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ""
Write-Output "========================================"
Write-Output "  Setup-NewPC"
Write-Output "========================================"
if ($DryRun) { Write-Output "Mode: DRY RUN (no changes will be made)" }
Write-Output ""

# ---------------------------------------------------------------------------
# Preflight: pending restart
# ---------------------------------------------------------------------------
# While Windows has a restart pending (typically after Windows Update, which a
# fresh install almost always has), CBS accepts new servicing sessions but
# parks them in its execution queue until the restart. A handful of winutil
# entries go through servicing (DISM / optional features); run everything
# else now and hand just those to a one-shot task that runs after the restart.
$resumeTaskName = 'Upkeep-SetupNewPC-Resume'

# winutil entries whose scripts call DISM / *-WindowsOptionalFeature /
# *-WindowsCapability. Every WPFFeature* entry installs an optional feature.
# AppX removal is NOT affected (works fine with a restart pending).
$servicingEntries = @('WPFTweaksWindowsAI', 'WPFTweaksDiskCleanup', 'WPFTweaksReservedStorage', 'WPFFixesNetwork')

function Test-ServicingEntry {
    param([string]$Id)
    return ($Id -like 'WPFFeature*') -or ($servicingEntries -contains $Id)
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

if (-not $DryRun) {
    # One-shot: whatever brought us here, the resume task has done its job.
    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$deferServicing = $false
if (Test-PendingReboot) {
    if ($IgnorePendingReboot) {
        Write-Output "[preflight] WARNING: Windows still reports a pending restart. Continuing;"
        Write-Output "[preflight] the tweaks phase is time-limited if servicing stays blocked."
    } else {
        $deferServicing = $true
        Write-Output "[preflight] Windows has a restart pending (usually from Windows Update)."
        Write-Output "[preflight] Everything runs now except the few tweaks that need Windows servicing;"
        Write-Output "[preflight] those are deferred. Restart manually when ready, then run setup again."
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# Phase 1: Restore point
# ---------------------------------------------------------------------------
if ($SkipRestorePoint) {
    Write-Output "[restore] Skipped by request."
    Add-PhaseResult 'Restore point' 'Skipped'
} elseif ($DryRun) {
    Write-Output "[restore] [dry-run] Would enable System Restore on $env:SystemDrive and create a restore point 'Setup-NewPC'."
    Add-PhaseResult 'Restore point' 'DryRun'
} else {
    Write-Output "[restore] Creating a System Restore point (does not replace a personal file backup)..."
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop

        # Windows silently refuses a second restore point within 24h unless
        # this frequency guard is lifted; set it to 0 like winutil does.
        $srPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        # Respect Windows restore-point frequency policy.

        Checkpoint-Computer -Description 'Setup-NewPC' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Output "[restore] Restore point created."
        Add-PhaseResult 'Restore point' 'OK'
    } catch {
        Write-Output "[restore] WARNING: Could not create a restore point: $($_.Exception.Message)"
        Write-Output "[restore] Continuing without one."
        Add-PhaseResult 'Restore point' 'Failed' $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Phase 2: winutil tweaks (headless via -Config)
# ---------------------------------------------------------------------------
try {
function Invoke-WinutilConfig {
    # Runs winutil headless on $ConfigPath in a child process with a time
    # limit. In-process, a DISM call stuck in the servicing queue cannot be
    # interrupted and would block every later phase; a child can be killed.
    param([string]$ConfigPath)

    $winutilCommand = Get-SettingString 'WinutilCommand' 'irm https://christitus.com/win | iex'
    $url = $null
    if ($winutilCommand -match '(?i)\b(?:irm|Invoke-RestMethod)\s+(\S+)') {
        $url = $Matches[1].Trim("'`"")
    }
    if (-not $url) { $url = 'https://christitus.com/win' }

    $timeoutMin = 20
    $parsedTimeout = 0
    if ([int]::TryParse((Get-SettingString 'WinutilTimeoutMin' ''), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
        $timeoutMin = $parsedTimeout
    }

    Write-Output "[tweaks] Downloading winutil from $url and applying '$ConfigPath' (this can take several minutes, limit $timeoutMin min)..."
    try {
        $winutilScript = Invoke-RestMethod -Uri $url -TimeoutSec 60 -ErrorAction Stop
        $workDir = Join-Path $env:TEMP 'Upkeep'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $winutilFile = Join-Path $workDir 'winutil.ps1'
        Set-Content -LiteralPath $winutilFile -Value $winutilScript -Encoding UTF8

        $selections = @((Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json))
        $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (Test-Path -LiteralPath $hosts) { Copy-Item -LiteralPath $hosts -Destination (Join-Path $reportDir 'hosts-before.txt') -ErrorAction Stop }
        foreach ($selection in $selections) {
            try {
                # Upstream rejects the entire import on unknown IDs. Isolate each
                # selection so a retired tweak cannot invalidate the others.
                if ($selection -notmatch '^WPF[A-Za-z0-9_]+$' -or $winutilScript -notmatch [regex]::Escape([string]$selection)) {
                    Add-PhaseResult "Tweak $selection" 'Skipped' 'No longer available in upstream winutil; other selections continue.'
                    continue
                }
                $singleConfig = Join-Path $reportDir 'winutil-selection.json'
                ConvertTo-Json -InputObject @($selection) | Set-Content -LiteralPath $singleConfig -Encoding UTF8
                $winutilArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$winutilFile`"", '-Config', "`"$singleConfig`"")
                $proc = Start-Process powershell.exe -ArgumentList $winutilArgs -NoNewWindow -PassThru
                $null = $proc.Handle
                try {
                    if (-not $proc.WaitForExit($timeoutMin * 60 * 1000)) {
                        & taskkill.exe /PID $proc.Id /T /F | Out-Null
                        throw "Timed out after $timeoutMin minutes. Restart manually if servicing is pending, then retry."
                    }
                    $proc.WaitForExit()
                    if ($proc.ExitCode -ne 0) { throw "winutil exited $($proc.ExitCode). See setup.log." }
                    Add-PhaseResult "Tweak $selection" 'Completed' 'winutil exited 0; review setup.log for upstream warnings.'
                } finally { $proc.Dispose() }
            } catch { Add-PhaseResult "Tweak $selection" 'Failed' $_.Exception.Message }
        }
    } catch {
        Write-Output "[tweaks] ERROR: winutil run failed: $($_.Exception.Message)"
        Add-PhaseResult 'Windows tweaks' 'Failed' $_.Exception.Message
    }

    # winutil's Adobe block-list tweak (WPFTweaksBlockAdobeNet) downloads a
    # hosts file and bare `Add-Content`s it, with no check for what is already
    # there. Re-running this setup therefore appends the whole list AGAIN --
    # observed at 1886 lines, 935 of them exact duplicates, and two nested
    # #AdobeNetBlock marker pairs. Nothing breaks (the resolver takes the first
    # match) but the file grows without bound every run.
    #
    # winutil is fetched fresh from the internet at run time, so its script
    # cannot be patched from here. Dedupe afterwards instead. Runs whether or
    # not winutil reported success: a partial run still appends.
    try { Repair-HostsFile } catch { Add-PhaseResult 'Hosts cleanup' 'Failed' $_.Exception.Message }
}

if (-not $SkipRestorePoint -and ($phaseResults | Where-Object { $_.Phase -eq 'Restore point' -and $_.Status -eq 'Failed' })) {
    Add-PhaseResult 'Windows tweaks' 'Deferred' 'Restore point failed. Fix System Protection before applying third-party tweaks.'
} elseif ($SkipTweaks) {
    Write-Output "[tweaks] Skipped by request."
    Add-PhaseResult 'Windows tweaks' 'Skipped'
} elseif (-not (Test-Path -LiteralPath $WinutilConfig)) {
    Write-Output "[tweaks] ERROR: winutil config not found: $WinutilConfig"
    Add-PhaseResult 'Windows tweaks' 'Failed' 'config not found'
} else {
    $ids = @()
    # Parenthesized: PS 5.1's ConvertFrom-Json emits a JSON array as ONE
    # pipeline object, so without it every id collapses into a single string.
    try { $ids = @((Get-Content -LiteralPath $WinutilConfig -Raw | ConvertFrom-Json) | ForEach-Object { [string]$_ }) } catch { Add-PhaseResult 'Windows tweaks' 'Failed' ('Invalid config: ' + $_.Exception.Message) }
    $deferredIds = @()
    if ($deferServicing) { $deferredIds = @($ids | Where-Object { Test-ServicingEntry $_ }) }
    $nowIds = @($ids | Where-Object { $deferredIds -notcontains $_ })

    if ($DryRun) {
        Write-Output "[tweaks] [dry-run] Would run winutil headless with config '$WinutilConfig' ($($nowIds.Count) selections: tweaks + junk-app removal)."
        if ($deferredIds.Count -gt 0) {
            Write-Output "[tweaks] [dry-run] Restart pending -- would schedule for after restart: $($deferredIds -join ', ')"
        }
        Add-PhaseResult 'Windows tweaks' 'DryRun'
    } else {
        $configNow = $WinutilConfig
        if ($deferredIds.Count -gt 0) {
            # Configs must survive the restart, so ProgramData rather than %TEMP%.
            $stateDir = $reportDir
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            $configNow = Join-Path $stateDir 'winutil-now.json'
            $configLater = Join-Path $stateDir 'winutil-after-restart.json'
            # -InputObject keeps a one-element list a JSON array (piping unrolls it).
            Set-Content -LiteralPath $configNow -Value (ConvertTo-Json -InputObject $nowIds) -Encoding UTF8
            Set-Content -LiteralPath $configLater -Value (ConvertTo-Json -InputObject $deferredIds) -Encoding UTF8
            Add-PhaseResult 'Tweaks after restart' 'Deferred' ("Restart manually, then re-run tweaks: " + ($deferredIds -join ', '))

        }

        if ($nowIds.Count -eq 0) {
            Write-Output "[tweaks] Nothing to apply before the restart."
            Add-PhaseResult 'Windows tweaks' 'Skipped' 'all selections need a restart first'
        } else {
            Invoke-WinutilConfig -ConfigPath $configNow
        }
    }
}


} catch { Add-PhaseResult 'Windows tweaks' 'Failed' $_.Exception.Message }
# ---------------------------------------------------------------------------
# Phase 3: registry toggles
# ---------------------------------------------------------------------------
# Registry values mirror winutil's toggle definitions (config/tweaks.json).
# winutil never applies toggles in headless -Config mode, so they live here.
$toggleDefs = @{
    'dark-theme'      = @(
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0; Type = 'DWord' }
    )
    'file-extensions' = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0; Type = 'DWord' }
    )
    'hidden-files'    = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Hidden'; Value = 1; Type = 'DWord' }
    )
    'mouse-accel-off' = @(
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed'; Value = '0'; Type = 'String' },
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Value = '0'; Type = 'String' },
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
    )
    'num-lock'        = @(
        @{ Path = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; Value = '2'; Type = 'String' },
        @{ Path = 'HKCU:\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; Value = '2'; Type = 'String' }
    )
    'sticky-keys-off' = @(
        @{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Value = '58'; Type = 'String' }
    )
    'verbose-bsod'    = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisplayParameters'; Value = 1; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisableEmoticon'; Value = 1; Type = 'DWord' }
    )
    'long-paths'      = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 1; Type = 'DWord' }
    )
}

if (-not $Toggles -or $Toggles.Count -eq 0) {
    Write-Output "[toggles] None selected."
    Add-PhaseResult 'Toggles' 'Skipped'
} else {
    $applied = New-Object System.Collections.Generic.List[string]
    $failedToggles = New-Object System.Collections.Generic.List[string]
    foreach ($slug in $Toggles) {
        if (-not $toggleDefs.ContainsKey($slug)) {
            Write-Output "[toggles] WARNING: unknown toggle '$slug' -- skipping."
            $failedToggles.Add($slug)
            continue
        }
        if ($DryRun) {
            Write-Output "[toggles] [dry-run] Would apply '$slug'."
            $applied.Add($slug)
            continue
        }
        try {
            foreach ($entry in $toggleDefs[$slug]) {
                $key = Get-Item -LiteralPath $entry.Path -ErrorAction SilentlyContinue
                $exists = $key -and ($key.GetValueNames() -contains $entry.Name)
                $registryBackup.Add([pscustomobject]@{ Path=$entry.Path; Name=$entry.Name; Exists=[bool]$exists; Value=$(if ($exists) { $key.GetValue($entry.Name) } else { $null }); Type=$(if ($exists) { [string]$key.GetValueKind($entry.Name) } else { $entry.Type }) })
                ConvertTo-Json -InputObject @($registryBackup.ToArray()) -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir 'registry-before.json') -Encoding UTF8
                if (-not (Test-Path -LiteralPath $entry.Path)) {
                    New-Item -Path $entry.Path -Force | Out-Null
                }
                Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.Type
            }
            Write-Output "[toggles] Applied '$slug'."
            $applied.Add($slug)
        } catch {
            Write-Output "[toggles] ERROR applying '$slug': $($_.Exception.Message)"
            $failedToggles.Add($slug)
        }
    }
    if ($failedToggles.Count -gt 0) {
        Add-PhaseResult 'Toggles' 'Failed' ("failed: " + ($failedToggles -join ', '))
    } elseif ($DryRun) {
        Add-PhaseResult 'Toggles' 'DryRun' ($applied -join ', ')
    } else {
        Add-PhaseResult 'Toggles' 'OK' ($applied -join ', ')
        Write-Output "[toggles] Some changes (theme, file extensions) show up after signing out or restarting."
    }
}

# ---------------------------------------------------------------------------
# Phase 4: drivers (SDIO + NVCleanstall package for NVIDIA)
# ---------------------------------------------------------------------------
try {
function Resolve-SdioExe {
    $dir = Get-SettingString 'SDIOPath'
    $candidates = @()
    if ($dir) {
        if ((Test-Path -LiteralPath $dir) -and $dir -match '\.exe$') { return $dir }
        if (Test-Path -LiteralPath $dir) {
            $candidates += Get-ChildItem -LiteralPath $dir -Filter 'SDIO*.exe' -ErrorAction SilentlyContinue
        }
    }
    $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPackages) {
        $candidates += Get-ChildItem -LiteralPath $wingetPackages -Directory -Filter 'GlennDelahoy.SnappyDriverInstallerOrigin_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'SDIO*.exe' -ErrorAction SilentlyContinue }
    }
    if ($candidates.Count -eq 0) { return $null }
    # The SDIO folder also ships Windows XP builds (SDIO-XP_x64_R887.exe);
    # never pick those when a regular build exists.
    $modern = @($candidates | Where-Object { $_.Name -notmatch '(?i)-XP' })
    if ($modern.Count -gt 0) { $candidates = $modern }
    # Prefer the lexicographically-newest x64 build, matching the dashboard.
    $x64 = @($candidates | Where-Object { $_.Name -match '(?i)x64' } | Sort-Object Name)
    if ($x64.Count -gt 0) { return $x64[-1].FullName }
    return (@($candidates | Sort-Object Name))[-1].FullName
}

# True when the URL answers at all (any HTTP status). SDIO's servers are
# intermittently unreachable or stall from some networks (Brazilian ISPs in
# particular): winget's download then times out and an unattended SDIO run
# without local driver packs hangs on the index/torrent download.
function Test-UrlReachable {
    param([string]$Url, [int]$TimeoutSec = 15)
    try {
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return [bool]$_.Exception.Response
    }
}

# Runs a process with a time limit; returns its exit code, or $null after
# killing the whole tree on timeout.
function Invoke-ProcessWithTimeout {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [int]$TimeoutMin)
    $startArgs = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; PassThru = $true; NoNewWindow = $true }
    if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }
    $proc = Start-Process @startArgs
    $null = $proc.Handle  # makes ExitCode readable after exit (PS 5.1)
    if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
        & taskkill.exe /PID $proc.Id /T /F | Out-Null
        return $null
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Get-SettingInt {
    param([string]$Name, [int]$Default)
    $parsed = 0
    if ([int]::TryParse((Get-SettingString $Name ''), [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

if ($SkipDrivers) {
    Write-Output "[drivers] Skipped by request."
    Add-PhaseResult 'Drivers (SDIO)' 'Skipped'
    Add-PhaseResult 'Drivers (NVIDIA)' 'Skipped'
 } else {
    if (-not $DryRun) {
        $driverBackup = Join-Path $reportDir 'drivers-before'
        New-Item -ItemType Directory -Path $driverBackup -Force | Out-Null
        $backupCode = Invoke-ProcessWithTimeout -FilePath pnputil.exe -ArgumentList @('/export-driver','*', "`"$driverBackup`"") -TimeoutMin 10
        if ($null -eq $backupCode -or $backupCode -ne 0) { throw 'Driver backup failed; automatic driver installation skipped. Use Windows Update or the PC manufacturer.' }
        Add-PhaseResult 'Driver backup' 'OK' $driverBackup
    }
    $sdioSite = 'https://www.glenn.delahoy.com/'
    $sdioExe = Resolve-SdioExe
    $sdioHasPacks = $false
    if ($sdioExe) {
        $sdioHasPacks = [bool](Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $sdioExe) 'drivers') -Filter '*.7z' -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    # Only probe when SDIO would have to download something.
    $sdioSiteUp = $true
    if (-not $DryRun -and -not $sdioHasPacks) {
        $sdioSiteUp = Test-UrlReachable $sdioSite
    }
    $sdioSkipReason = $null

    if (-not $sdioExe -and -not $DryRun) {
        if (-not $sdioSiteUp) {
            $sdioSkipReason = 'SDIO download site unreachable from this network'
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Output "[drivers] SDIO not found -- installing via winget (limit 10 min)..."
            $wingetExit = Invoke-ProcessWithTimeout -FilePath 'winget' -ArgumentList @('install', '--id', 'GlennDelahoy.SnappyDriverInstallerOrigin', '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent') -TimeoutMin 10
            if ($null -eq $wingetExit) { Write-Output "[drivers] winget install of SDIO timed out -- stopped it." }
            $sdioExe = Resolve-SdioExe
            if (-not $sdioExe) { $sdioSkipReason = 'SDIO could not be downloaded (slow or blocked download server)' }
        }
    } elseif ($sdioExe -and -not $sdioHasPacks -and -not $sdioSiteUp) {
        $sdioSkipReason = 'no local driver packs and the SDIO download site is unreachable'
    }

    if ($DryRun) {
        $shown = if ($sdioExe) { $sdioExe } else { '<would install via winget>' }
        if (-not $sdioSiteUp -and -not $sdioHasPacks) {
            Write-Output "[drivers] [dry-run] SDIO download site unreachable and no local driver packs -- would skip SDIO."
        } else {
            Write-Output "[drivers] [dry-run] Would run SDIO ($shown) with: -autoinstall -autoclose -license -norestorepnt -nostop"
        }
        Add-PhaseResult 'Drivers (SDIO)' 'DryRun'
    } elseif ($sdioSkipReason) {
        Write-Output "[drivers] Skipping SDIO: $sdioSkipReason."
        Write-Output "[drivers] (Known to happen from some Brazilian networks.) Windows Update and the PC maker's updater"
        Write-Output "[drivers] (Dell Command | Update, Lenovo Vantage, HP Support Assistant) still provide drivers."
        Add-PhaseResult 'Drivers (SDIO)' 'Skipped' $sdioSkipReason
    } elseif (-not $sdioExe) {
        Write-Output "[drivers] ERROR: SDIO could not be found or installed. Set SDIOPath in settings.json."
        Add-PhaseResult 'Drivers (SDIO)' 'Failed' 'SDIO not found'
    } else {
        $sdioTimeoutMin = Get-SettingInt 'SDIOTimeoutMin' 45
        Write-Output "[drivers] Running SDIO in automatic mode (limit $sdioTimeoutMin min): $sdioExe"
        Write-Output "[drivers] It installs only drivers it marks as missing or better, and may first download driver packs (can take a while on a fresh PC)."
        try {
            # -norestorepnt: we already made our own restore point above.
            $sdioArgs = @('-autoinstall', '-autoclose', '-license', '-norestorepnt', '-nostop')
            $sdioExit = Invoke-ProcessWithTimeout -FilePath $sdioExe -ArgumentList $sdioArgs -WorkingDirectory (Split-Path -Parent $sdioExe) -TimeoutMin $sdioTimeoutMin
            if ($null -eq $sdioExit) {
                Write-Output "[drivers] SDIO did not finish within $sdioTimeoutMin min (stalled driver-pack download?) -- stopped it and continuing."
                Add-PhaseResult 'Drivers (SDIO)' 'Failed' "timed out after $sdioTimeoutMin min"
            } else {
                Write-Output "[drivers] SDIO finished (exit code $sdioExit)."
                if ($sdioExit -in @(0,3010)) { Add-PhaseResult 'Drivers (SDIO)' 'OK' "exit $sdioExit" } else { Add-PhaseResult 'Drivers (SDIO)' 'Failed' "exit $sdioExit" }
            }
        } catch {
            Write-Output "[drivers] ERROR: SDIO run failed: $($_.Exception.Message)"
            Add-PhaseResult 'Drivers (SDIO)' 'Failed' $_.Exception.Message
        }
    }

    Add-PhaseResult 'USB4 driver check' 'Skipped' 'Machine-specific repair is available separately; not applied automatically.'

    # NVIDIA GPU -> prefer the clean NVCleanstall-built package if prepared.
    $hasNvidia = $false
    try {
        $hasNvidia = [bool](Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' })
    } catch {
        Write-Output "[drivers] WARNING: could not query the GPU: $($_.Exception.Message)"
    }

    if (-not $hasNvidia) {
        Write-Output "[drivers] No NVIDIA GPU detected -- skipping NVCleanstall."
        Add-PhaseResult 'Drivers (NVIDIA)' 'Skipped' 'no NVIDIA GPU'
    } else {
        $nvPkg = Get-SettingString 'NVCleanPackagePath'
        if ($nvPkg -and (Test-Path -LiteralPath $nvPkg)) {
            if ($DryRun) {
                Write-Output "[drivers] [dry-run] Would run NVCleanstall package: $nvPkg -y -noreboot"
                Add-PhaseResult 'Drivers (NVIDIA)' 'DryRun'
            } else {
                Write-Output "[drivers] NVIDIA GPU found -- running the prebuilt NVCleanstall package (no telemetry, no restart)..."
                try {
                    $nvExit = Invoke-ProcessWithTimeout -FilePath $nvPkg -ArgumentList @('-y', '-noreboot') -TimeoutMin 30
                    if ($null -eq $nvExit -or $nvExit -notin @(0,3010)) { throw "Driver installer failed or timed out: $nvExit" }
                    Write-Output "[drivers] NVCleanstall package finished (exit code $nvExit)."
                    Add-PhaseResult 'Drivers (NVIDIA)' 'OK' "exit $nvExit"
                } catch {
                    Write-Output "[drivers] ERROR: NVCleanstall package failed: $($_.Exception.Message)"
                    Add-PhaseResult 'Drivers (NVIDIA)' 'Failed' $_.Exception.Message
                }
            }
        } else {
            # No prebuilt package: fall back to the fully automatic clean
            # driver script (NVIDIA lookup -> core-only extract -> silent).
            $nvScript = Join-Path $PSScriptRoot 'Get-NvidiaDriver.ps1'
            if (Test-Path -LiteralPath $nvScript) {
                if ($DryRun) {
                    Write-Output "[drivers] [dry-run] Would run Get-NvidiaDriver.ps1 -Install -KeepAudio (automatic clean driver)."
                    Add-PhaseResult 'Drivers (NVIDIA)' 'DryRun'
                } else {
                    Write-Output "[drivers] NVIDIA GPU found - running the automatic clean driver update..."
                    $LASTEXITCODE = Invoke-ProcessWithTimeout -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$nvScript`"", '-Install','-KeepAudio') -TimeoutMin 40
                    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -in @(0,3010)) {
                        Add-PhaseResult 'Drivers (NVIDIA)' 'OK' "clean driver (exit $LASTEXITCODE)"
                    } else {
                        Add-PhaseResult 'Drivers (NVIDIA)' 'Failed' "exit $LASTEXITCODE"
                    }
                }
            } else {
                Write-Output "[drivers] NVIDIA GPU found, but no NVCleanstall package and no Get-NvidiaDriver.ps1."
                Add-PhaseResult 'Drivers (NVIDIA)' 'Skipped' 'no automation available'
            }
        }
    }
}


} catch { Add-PhaseResult 'Drivers' 'Failed' $_.Exception.Message }
# ---------------------------------------------------------------------------
# Phase 5: O&O ShutUp10++ (privacy settings)
# ---------------------------------------------------------------------------
try {
if (-not $Oosu) {
    Write-Output "[oosu] Not requested (pass -Oosu to include O&O ShutUp10++)."
    Add-PhaseResult 'O&O ShutUp10++' 'Skipped'
} else {
    # Config resolution for auto mode: the user's exported config wins, then
    # the bundled recommended preset shipped next to this script.
    $oosuCfg = Get-SettingString 'OOSUConfigPath'
    if (-not ($oosuCfg -and (Test-Path -LiteralPath $oosuCfg))) {
        $bundled = Join-Path $PSScriptRoot (Join-Path 'presets' 'ooshutup10-recommended.cfg')
        $oosuCfg = if (Test-Path -LiteralPath $bundled) { $bundled } else { '' }
    }
    $autoPossible = ($OosuMode -eq 'auto') -and $oosuCfg
    $oosuDir = Join-Path $env:TEMP 'Upkeep'
    $oosuExe = Join-Path $oosuDir 'OOSU10.exe'

    if ($DryRun) {
        if ($autoPossible) {
            Write-Output "[oosu] [dry-run] Would download OOSU10.exe and silently apply '$oosuCfg' (/quiet)."
        } else {
            Write-Output "[oosu] [dry-run] Would download OOSU10.exe and open its window for manual review."
        }
        Add-PhaseResult 'O&O ShutUp10++' 'DryRun'
    } else {
        try {
            if (-not (Test-Path -LiteralPath $oosuExe)) {
                Write-Output "[oosu] Downloading O&O ShutUp10++..."
                New-Item -ItemType Directory -Path $oosuDir -Force | Out-Null
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -OutFile $oosuExe -UseBasicParsing -TimeoutSec 60
                $ProgressPreference = 'Continue'
            }
            if ((Get-AuthenticodeSignature -LiteralPath $oosuExe).Status -ne 'Valid') { throw 'O&O executable has no valid publisher signature.' }
            if ($autoPossible) {
                Write-Output "[oosu] Applying privacy settings silently from: $oosuCfg"
                # /nosrp: we already created our own restore point above.
                $oosuExit = Invoke-ProcessWithTimeout -FilePath $oosuExe -ArgumentList @("`"$oosuCfg`"", '/quiet') -TimeoutMin 10
                if ($null -eq $oosuExit -or $oosuExit -ne 0) { throw "O&O failed or timed out: $oosuExit" }
                Write-Output "[oosu] Done (exit code $oosuExit)."
                Add-PhaseResult 'O&O ShutUp10++' 'OK' 'applied silently'
            } else {
                if ($OosuMode -eq 'auto') {
                    Write-Output "[oosu] No config available for auto mode -- falling back to the app window."
                }
                Write-Output "[oosu] Opening the O&O ShutUp10++ window. In it, click: Actions > Apply only recommended settings."
                Write-Output "[oosu] Tip: afterwards use File > Export settings, save the .cfg, and put its path in settings.json"
                Write-Output "[oosu] as OOSUConfigPath -- future automatic runs will use your own selection."
                Start-Process -FilePath $oosuExe
                Add-PhaseResult 'O&O ShutUp10++' 'Manual' 'opened for manual review; no automatic changes confirmed'
            }
        } catch {
            Write-Output "[oosu] ERROR: $($_.Exception.Message)"
            Add-PhaseResult 'O&O ShutUp10++' 'Failed' $_.Exception.Message
        }
    }
}


} catch { Add-PhaseResult 'Privacy' 'Failed' $_.Exception.Message }
# ---------------------------------------------------------------------------
# Phase 6: apps
# ---------------------------------------------------------------------------
if ($SkipApps) {
    Write-Output "[apps] Skipped by request."
    Add-PhaseResult 'Apps' 'Skipped'
} else {
    $installScript = Join-Path $PSScriptRoot 'Install-Apps.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        Write-Output "[apps] ERROR: Install-Apps.ps1 not found next to this script."
        Add-PhaseResult 'Apps' 'Failed' 'Install-Apps.ps1 missing'
    } else {
        Write-Output "[apps] Installing the '$AppsPreset' app pack..."
        # Hashtable splat: array splatting binds positionally on ps1 scripts,
        # which silently drops the -DryRun switch (verified the hard way).
        $appArgs = @{ Preset = $AppsPreset; NoRebootPrompt=$true; ResultFile=$setupAppReport }
        if ($DryRun) { $appArgs.DryRun = $true }
        # Already elevated here, so Install-Apps.ps1 will not re-prompt.
        try { & $installScript @appArgs; $appsExit = $LASTEXITCODE } catch { Write-Warning $_; $appsExit = 1 }
        if ($DryRun) {
            Add-PhaseResult 'Apps' 'DryRun'
        } elseif ($appsExit -eq 0) {
            Add-PhaseResult 'Apps' 'OK'
        } else {
            Add-PhaseResult 'Apps' 'Failed' "exit $appsExit"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "========================================"
Write-Output "  SETUP SUMMARY"
Write-Output "========================================"
$phaseResults | Format-Table -AutoSize -Property Phase, Status, Detail | Out-String | Write-Output

try { Stop-Transcript -ErrorAction Stop | Out-Null } catch {}
$failedPhases = @($phaseResults | Where-Object { $_.Status -eq 'Failed' })
if (-not $DryRun -and -not $NoRebootPrompt) {
    try {
        . (Join-Path $PSScriptRoot 'steps\Setup-Resume.ps1')
        $appResults = @()
        if (Test-Path -LiteralPath $setupAppReport) { $appResults = @((Get-Content -LiteralPath $setupAppReport -Raw | ConvertFrom-Json)) }
        $needsRestart = (Test-PendingReboot) -or [bool]($appResults | Where-Object { $_.ExitCode -eq 3010 }) -or [bool]($phaseResults | Where-Object { $_.Detail -match '\b3010\b' })
        Request-SetupResume -Root $PSScriptRoot -Apps @(Get-RebootApps $appResults) -Tweaks $deferredIds -RestartRequired:$needsRestart
    } catch { Write-Warning "Could not arrange continuation; no restart requested: $_" }
}
if ($failedPhases.Count -gt 0) {
    Write-Output "Some phases failed: $(($failedPhases | ForEach-Object { $_.Phase }) -join ', ')"
    exit 1
}
if ($deferredIds.Count) { exit 3010 }
exit 0
