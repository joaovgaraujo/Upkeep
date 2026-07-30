<#
.SYNOPSIS
    One-shot basic setup for a fresh Windows installation: restore point,
    curated winutil tweaks + junk-app removal, quality-of-life registry
    toggles, drivers (SDIO, plus NVCleanstall package for NVIDIA GPUs) and
    the essentials app pack.

.DESCRIPTION
    Orchestrates the phases below in order. Each phase can be skipped, and
    every change is preceded by a System Restore point so it can be undone.

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
    [switch]$SkipApps,

    [Parameter()]
    [string[]]$Toggles = @('dark-theme', 'file-extensions', 'hidden-files', 'mouse-accel-off', 'num-lock', 'sticky-keys-off', 'verbose-bsod', 'long-paths'),

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

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

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

if ($DryRun) {
    if (-not (Test-IsAdmin)) {
        Write-Output "Not running as administrator -- continuing anyway because -DryRun makes no changes."
    }
} elseif (-not (Test-IsAdmin)) {
    Write-Output "Not running as administrator. Requesting elevation..."

    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")

    if ($SkipRestorePoint) { $argList += '-SkipRestorePoint' }
    if ($SkipTweaks)       { $argList += '-SkipTweaks' }
    if ($SkipDrivers)      { $argList += '-SkipDrivers' }
    if ($SkipApps)         { $argList += '-SkipApps' }
    if ($Oosu)             { $argList += @('-Oosu', '-OosuMode', $OosuMode) }
    if ($Toggles)          { $argList += @('-Toggles', ($Toggles -join ',')) }
    if ($AppsPreset)       { $argList += @('-AppsPreset', "`"$AppsPreset`"") }
    if ($WinutilConfig)    { $argList += @('-WinutilConfig', "`"$WinutilConfig`"") }

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
$phaseResults = New-Object System.Collections.Generic.List[object]

function Add-PhaseResult {
    param([string]$Phase, [string]$Status, [string]$Detail = '')
    $phaseResults.Add([pscustomobject]@{ Phase = $Phase; Status = $Status; Detail = $Detail })
}

Write-Output ""
Write-Output "========================================"
Write-Output "  Setup-NewPC"
Write-Output "========================================"
if ($DryRun) { Write-Output "Mode: DRY RUN (no changes will be made)" }
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
    Write-Output "[restore] Creating a System Restore point (your undo button for everything below)..."
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop

        # Windows silently refuses a second restore point within 24h unless
        # this frequency guard is lifted; set it to 0 like winutil does.
        $srPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        Set-ItemProperty -Path $srPath -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord

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
if ($SkipTweaks) {
    Write-Output "[tweaks] Skipped by request."
    Add-PhaseResult 'Windows tweaks' 'Skipped'
} elseif (-not (Test-Path -LiteralPath $WinutilConfig)) {
    Write-Output "[tweaks] ERROR: winutil config not found: $WinutilConfig"
    Add-PhaseResult 'Windows tweaks' 'Failed' 'config not found'
} elseif ($DryRun) {
    $ids = @()
    try { $ids = Get-Content -LiteralPath $WinutilConfig -Raw | ConvertFrom-Json } catch {}
    Write-Output "[tweaks] [dry-run] Would run winutil headless with config '$WinutilConfig' ($($ids.Count) selections: tweaks + junk-app removal)."
    Add-PhaseResult 'Windows tweaks' 'DryRun'
} else {
    # winutil's -Config mode imports the selection and auto-runs tweaks,
    # features, app installs and appx removals, then exits without a GUI.
    $winutilCommand = Get-SettingString 'WinutilCommand' 'irm https://christitus.com/win | iex'
    $url = $null
    if ($winutilCommand -match '(?i)\b(?:irm|Invoke-RestMethod)\s+(\S+)') {
        $url = $Matches[1].Trim("'`"")
    }
    if (-not $url) { $url = 'https://christitus.com/win' }

    Write-Output "[tweaks] Downloading winutil from $url and applying '$WinutilConfig' (this can take several minutes)..."
    try {
        $winutilScript = Invoke-RestMethod -Uri $url -ErrorAction Stop
        $configFull = (Resolve-Path -LiteralPath $WinutilConfig).Path
        Invoke-Expression "& { $winutilScript } -Config '$configFull'"
        Write-Output "[tweaks] winutil finished."
        Add-PhaseResult 'Windows tweaks' 'OK'
    } catch {
        Write-Output "[tweaks] ERROR: winutil run failed: $($_.Exception.Message)"
        Add-PhaseResult 'Windows tweaks' 'Failed' $_.Exception.Message
    }
}

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
            continue
        }
        if ($DryRun) {
            Write-Output "[toggles] [dry-run] Would apply '$slug'."
            $applied.Add($slug)
            continue
        }
        try {
            foreach ($entry in $toggleDefs[$slug]) {
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
    # Prefer the lexicographically-newest x64 build, matching the dashboard.
    $x64 = @($candidates | Where-Object { $_.Name -match '(?i)x64' } | Sort-Object Name)
    if ($x64.Count -gt 0) { return $x64[-1].FullName }
    return (@($candidates | Sort-Object Name))[-1].FullName
}

if ($SkipDrivers) {
    Write-Output "[drivers] Skipped by request."
    Add-PhaseResult 'Drivers (SDIO)' 'Skipped'
    Add-PhaseResult 'Drivers (NVIDIA)' 'Skipped'
} else {
    $sdioExe = Resolve-SdioExe

    if (-not $sdioExe -and -not $DryRun) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Output "[drivers] SDIO not found -- installing via winget..."
            & winget install --id GlennDelahoy.SnappyDriverInstallerOrigin -e --accept-package-agreements --accept-source-agreements --silent
            $sdioExe = Resolve-SdioExe
        }
    }

    if ($DryRun) {
        $shown = if ($sdioExe) { $sdioExe } else { '<would install via winget>' }
        Write-Output "[drivers] [dry-run] Would run SDIO ($shown) with: -autoinstall -autoclose -license -norestorepnt -nostop"
        Add-PhaseResult 'Drivers (SDIO)' 'DryRun'
    } elseif (-not $sdioExe) {
        Write-Output "[drivers] ERROR: SDIO could not be found or installed. Set SDIOPath in settings.json."
        Add-PhaseResult 'Drivers (SDIO)' 'Failed' 'SDIO not found'
    } else {
        Write-Output "[drivers] Running SDIO in automatic mode: $sdioExe"
        Write-Output "[drivers] It installs only drivers it marks as missing or better, and may first download driver packs (can take a while on a fresh PC)."
        try {
            # -norestorepnt: we already made our own restore point above.
            $sdioArgs = @('-autoinstall', '-autoclose', '-license', '-norestorepnt', '-nostop')
            $proc = Start-Process -FilePath $sdioExe -ArgumentList $sdioArgs -WorkingDirectory (Split-Path -Parent $sdioExe) -Wait -PassThru
            Write-Output "[drivers] SDIO finished (exit code $($proc.ExitCode))."
            Add-PhaseResult 'Drivers (SDIO)' 'OK' "exit $($proc.ExitCode)"
        } catch {
            Write-Output "[drivers] ERROR: SDIO run failed: $($_.Exception.Message)"
            Add-PhaseResult 'Drivers (SDIO)' 'Failed' $_.Exception.Message
        }
    }

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
                    $proc = Start-Process -FilePath $nvPkg -ArgumentList @('-y', '-noreboot') -Wait -PassThru
                    Write-Output "[drivers] NVCleanstall package finished (exit code $($proc.ExitCode))."
                    Add-PhaseResult 'Drivers (NVIDIA)' 'OK' "exit $($proc.ExitCode)"
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
                    & $nvScript -Install -KeepAudio
                    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
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

# ---------------------------------------------------------------------------
# Phase 5: O&O ShutUp10++ (privacy settings)
# ---------------------------------------------------------------------------
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
                Invoke-WebRequest -Uri 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -OutFile $oosuExe
                $ProgressPreference = 'Continue'
            }
            if ($autoPossible) {
                Write-Output "[oosu] Applying privacy settings silently from: $oosuCfg"
                # /nosrp: we already created our own restore point above.
                $proc = Start-Process -FilePath $oosuExe -ArgumentList @("`"$oosuCfg`"", '/quiet', '/nosrp') -Wait -PassThru
                Write-Output "[oosu] Done (exit code $($proc.ExitCode))."
                Add-PhaseResult 'O&O ShutUp10++' 'OK' 'applied silently'
            } else {
                if ($OosuMode -eq 'auto') {
                    Write-Output "[oosu] No config available for auto mode -- falling back to the app window."
                }
                Write-Output "[oosu] Opening the O&O ShutUp10++ window. In it, click: Actions > Apply only recommended settings."
                Write-Output "[oosu] Tip: afterwards use File > Export settings, save the .cfg, and put its path in settings.json"
                Write-Output "[oosu] as OOSUConfigPath -- future automatic runs will use your own selection."
                Start-Process -FilePath $oosuExe
                Add-PhaseResult 'O&O ShutUp10++' 'OK' 'opened for manual review'
            }
        } catch {
            Write-Output "[oosu] ERROR: $($_.Exception.Message)"
            Add-PhaseResult 'O&O ShutUp10++' 'Failed' $_.Exception.Message
        }
    }
}

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
        $appArgs = @{ Preset = $AppsPreset }
        if ($DryRun) { $appArgs.DryRun = $true }
        # Already elevated here, so Install-Apps.ps1 will not re-prompt.
        & $installScript @appArgs
        $appsExit = $LASTEXITCODE
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

$failedPhases = @($phaseResults | Where-Object { $_.Status -eq 'Failed' })
if (-not $DryRun) {
    Write-Output "A restart is recommended to finish applying drivers and tweaks."
}
if ($failedPhases.Count -gt 0) {
    Write-Output "Some phases failed: $(($failedPhases | ForEach-Object { $_.Phase }) -join ', ')"
    exit 1
}
exit 0
