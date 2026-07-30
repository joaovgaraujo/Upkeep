@echo off
setlocal enabledelayedexpansion
rem ============================================================
rem  SystemUpdate_Portable.bat
rem  Self-elevating launcher that extracts and runs the embedded
rem  PowerShell script below the PS_START marker.
rem ============================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PSFILE=%TEMP%\SystemUpdate_%RANDOM%%RANDOM%.ps1"

rem Extract everything after the PS_START marker into a UTF-8 .ps1 (no BOM).
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$lines=Get-Content -LiteralPath '%~f0'; $idx=-1; for($j=0;$j -lt $lines.Count;$j++){if($lines[$j].Trim() -eq ('# POWER'+'SHELL_START')){$idx=$j;break}}; if($idx -lt 0){exit 1}; $payload=$lines[$idx..($lines.Count-1)] -join [Environment]::NewLine; [IO.File]::WriteAllText('%PSFILE%',$payload,(New-Object Text.UTF8Encoding $false))"

if not exist "%PSFILE%" (
    echo Failed to extract PowerShell payload.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
del "%PSFILE%" 2>nul
exit /b

# POWERSHELL_START
# ============================================================
#  System Maintenance and Update Script (PowerShell payload)
# ============================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'Continue'

# ---- Config ------------------------------------------------------------------
$ExcludePatterns = @(
    'adobe.acrobat',
    'adoberdr',
    'adobe acrobat',
    'adobe reader',
    'bluestacks',
    'amazon.kiro'
)

$TimeoutStore        = 180
$TimeoutWingetPkg    = 300
$TimeoutChocoPkg     = 600
$TimeoutWindowsUpd   = 1800

$RunDefenderUpdate   = $true
$StartTranscript     = $true

# ---- Logging -----------------------------------------------------------------
$docsFolder = [Environment]::GetFolderPath('MyDocuments')
$logDir     = Join-Path $docsFolder 'SystemUpdateLogs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$stamp           = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile         = Join-Path $logDir "SystemUpdate_$stamp.log"
$transcriptFile  = Join-Path $logDir "SystemUpdate_$stamp.transcript.log"

if ($StartTranscript) {
    try { Start-Transcript -Path $transcriptFile -Force | Out-Null } catch {}
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','SKIP')][string]$Type = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Type, $Message
    $line | Out-File -FilePath $logFile -Append -Encoding UTF8
    switch ($Type) {
        'ERROR' { Write-Host "  [X] $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "  [+] $Message" -ForegroundColor Green }
        'SKIP'  { Write-Host "  [-] $Message" -ForegroundColor DarkGray }
        default { Write-Host "  [i] $Message" -ForegroundColor Cyan }
    }
}

function Test-Excluded {
    param([string]$Id, [string]$Name)
    foreach ($p in $ExcludePatterns) {
        if ($Id   -and $Id   -match [regex]::Escape($p)) { return $true }
        if ($Name -and $Name -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

function Invoke-WithTimeout {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300,
        [string]$Activity     = 'Working',
        [switch]$ShowProgress
    )
    $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgumentList
    $elapsed = 0
    while ($job.State -eq 'Running' -and $elapsed -lt $TimeoutSeconds) {
        if ($ShowProgress) {
            $pct = [math]::Min(($elapsed / $TimeoutSeconds) * 100, 99)
            Write-Progress -Activity $Activity -Status "Running... ($elapsed s)" -PercentComplete $pct
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    if ($ShowProgress) { Write-Progress -Activity $Activity -Completed }
    $timedOut = $false
    if ($job.State -eq 'Running') { Stop-Job $job | Out-Null; $timedOut = $true }
    $raw = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force
    [pscustomobject]@{
        Result   = $raw
        Text     = ($raw | Out-String)
        TimedOut = $timedOut
        Elapsed  = $elapsed
    }
}

# ---- Step orchestration ------------------------------------------------------
$steps   = @(
    'Launch game/download clients',
    'Microsoft Store updates',
    'Winget updates',
    'Chocolatey updates',
    'Launch Discord/Battle.net',
    'Windows Updates',
    'Defender signatures'
)
$stepNum = 0
$total   = $steps.Count
function Write-Step([string]$Title) {
    $script:stepNum++
    Write-Host "`n[$script:stepNum/$total] $Title" -ForegroundColor White
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  System Maintenance Script"               -ForegroundColor Cyan
Write-Host "  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Excluding: $($ExcludePatterns -join ', ')" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan

$startTime = Get-Date
$summary = [ordered]@{}

$pf86 = ${env:ProgramFiles(x86)}
$pf   = $env:ProgramFiles

# ===== Step 1: launch apps with their own updaters ===========================
Write-Step $steps[0]
$appsToLaunch = @(
    @{ Name = 'Steam';         Paths = @("$pf86\Steam\Steam.exe", "$pf\Steam\Steam.exe") },
    @{ Name = 'EA App';        Paths = @("$pf\Electronic Arts\EA Desktop\EA Desktop\EALauncher.exe") },
    @{ Name = 'Epic Games';    Paths = @(
        "$pf\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
        "$pf86\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
        "$pf\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe",
        "$pf86\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe"
    ) },
    @{ Name = 'JDownloader 2'; Paths = @("$pf\JDownloader\JDownloader2.exe", "C:\Program Files\JDownloader\JDownloader2.exe", "C:\Program Files\JDownloader 2\JDownloader2.exe") }
)
$launched = 0
foreach ($app in $appsToLaunch) {
    $path = $app.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($path) {
        try {
            Start-Process -FilePath $path -ErrorAction Stop
            Write-Log "$($app.Name) launched" 'OK'
            $launched++
        } catch {
            Write-Log "$($app.Name) launch failed: $_" 'WARN'
        }
    } else {
        Write-Log "$($app.Name) not installed" 'SKIP'
    }
}
$summary['Apps launched'] = $launched
Start-Sleep -Seconds 3

# ===== Step 2: Microsoft Store ===============================================
Write-Step $steps[1]
try {
    $r = Invoke-WithTimeout -TimeoutSeconds $TimeoutStore -Activity 'Microsoft Store Updates' -ShowProgress -Script {
        try {
            Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
                Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
        } catch {}
        try {
            winget upgrade --all --source msstore --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-String
        } catch {}
    }
    if ($r.TimedOut) { Write-Log "Store update scan timed out after $TimeoutStore s" 'WARN' }
    else            { Write-Log 'Store update scan completed' 'OK' }
    $summary['Store scan'] = if ($r.TimedOut) { 'timeout' } else { 'ok' }
} catch {
    Write-Log "Store updates failed: $_" 'ERROR'
    $summary['Store scan'] = 'error'
}

# ===== Step 3: Winget ========================================================
Write-Step $steps[2]
$wingetSuccess = 0; $wingetFail = 0; $wingetSkip = 0
if (Get-Command winget -ErrorAction SilentlyContinue) {
    try {
        winget source update --accept-source-agreements 2>&1 | Out-Null

        $raw   = winget upgrade --include-unknown --accept-source-agreements 2>&1 | Out-String
        $lines = $raw -split "`r?`n"

        $packages = @()
        $sepIdxs  = for ($h = 0; $h -lt $lines.Count; $h++) { if ($lines[$h] -match '^-{10,}') { $h } }

        foreach ($sep in $sepIdxs) {
            if ($sep -lt 1) { continue }
            $header = $lines[$sep - 1]
            $idPos  = $header.IndexOf('Id')
            $verPos = $header.IndexOf('Version')
            if ($idPos -lt 0 -or $verPos -lt 0) { continue }

            for ($h = $sep + 1; $h -lt $lines.Count; $h++) {
                $line = $lines[$h]
                if ([string]::IsNullOrWhiteSpace($line))                    { break }
                if ($line -match '^\d+\s+(upgrades?|packages?)')            { break }
                if ($line -match '^The following')                          { break }
                if ($line.Length -lt $verPos)                               { continue }

                $id   = $line.Substring($idPos, $verPos - $idPos).Trim()
                $name = $line.Substring(0, [math]::Min($idPos, $line.Length)).Trim()
                if ($id -notmatch '^\S+\.\S+')                            { continue }
                if ($packages | Where-Object { $_.Id -eq $id })            { continue }
                $packages += [pscustomobject]@{ Name = $name; Id = $id }
            }
        }

        # Filter excluded
        $filtered = @()
        foreach ($p in $packages) {
            if (Test-Excluded -Id $p.Id -Name $p.Name) {
                Write-Log "Excluded: $($p.Id)" 'SKIP'
                $wingetSkip++
            } else { $filtered += $p }
        }

        if ($filtered.Count -eq 0) {
            Write-Log 'No Winget updates to apply' 'INFO'
        } else {
            Write-Log "Found $($filtered.Count) Winget package(s) to update" 'INFO'

            for ($i = 0; $i -lt $filtered.Count; $i++) {
                $pkg = $filtered[$i]
                $pct = [math]::Round((($i + 1) / $filtered.Count) * 100)
                Write-Progress -Activity 'Updating Winget Apps' -Status "[$($i+1)/$($filtered.Count)] $($pkg.Id)" -PercentComplete $pct
                Write-Host "  [$($i+1)/$($filtered.Count)] $($pkg.Id)..." -ForegroundColor Gray -NoNewline

                $r = Invoke-WithTimeout -TimeoutSeconds $TimeoutWingetPkg -Script {
                    param($id)
                    $out = winget upgrade --id $id --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-String
                    [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
                } -ArgumentList $pkg.Id

                $text     = if ($r.Result) { $r.Result.Output } else { '' }
                $exitCode = if ($r.Result) { [int]$r.Result.ExitCode } else { 0 }

                $isOk    = $false
                $reason  = ''
                $retry   = $null

                if ($r.TimedOut)                                             { $reason = " timeout(${TimeoutWingetPkg}s)" }
                elseif ($exitCode -eq 0 -and $text -match 'Successfully installed') { $isOk = $true }
                elseif ($exitCode -eq 0)                                     { $isOk = $true }
                elseif ($text -match 'No applicable upgrade|No newer version|already installed') { $isOk = $true; $reason = ' (already newest)' }
                elseif ($text -match 'install technology is different' -or $exitCode -eq -1978334956) { $retry = '--uninstall-previous'; $reason = ' (different installer, retry)' }
                elseif ($text -match 'hash.*does not match|Installer hash does not match' -or $exitCode -eq -1978335145) { $retry = '--force'; $reason = ' (hash mismatch, retry)' }
                elseif ($text -match 'No installed package' -or $exitCode -eq -1978335212) { $reason = ' (not recognized)' }
                elseif ($text -match 'application is currently running' -or $exitCode -eq -1978335159) { $reason = ' (app running)' }
                else                                                         { $reason = " (exit $exitCode)" }

                if (-not $isOk -and $retry) {
                    $r2 = Invoke-WithTimeout -TimeoutSeconds $TimeoutWingetPkg -Script {
                        param($id, $extra)
                        $out = winget upgrade --id $id --silent --accept-source-agreements --accept-package-agreements --disable-interactivity $extra 2>&1 | Out-String
                        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
                    } -ArgumentList $pkg.Id, $retry
                    $text2 = if ($r2.Result) { $r2.Result.Output } else { '' }
                    $code2 = if ($r2.Result) { [int]$r2.Result.ExitCode } else { 0 }
                    if ($r2.TimedOut)              { $reason = ' (retry timeout)' }
                    elseif ($code2 -eq 0)          { $isOk = $true; $reason = ' (retry ok)' }
                    elseif ($text2 -match 'Successfully installed') { $isOk = $true; $reason = ' (retry ok)' }
                    else                           { $reason = " (retry exit $code2)" }
                }

                if ($isOk) {
                    Write-Host " OK$reason" -ForegroundColor Green
                    Write-Log  "winget OK: $($pkg.Id)$reason" 'OK'
                    $wingetSuccess++
                } else {
                    Write-Host " SKIP$reason" -ForegroundColor Yellow
                    Write-Log  "winget FAIL: $($pkg.Id)$reason" 'WARN'
                    $wingetFail++
                }
            }
            Write-Progress -Activity 'Updating Winget Apps' -Completed
        }
    } catch {
        Write-Log "Winget failed: $_" 'ERROR'
    }
} else {
    Write-Log 'Winget not installed' 'WARN'
}
$summary['Winget'] = "$wingetSuccess ok, $wingetFail fail, $wingetSkip skipped"

# ===== Step 4: Chocolatey ====================================================
Write-Step $steps[3]
$chocoSuccess = 0; $chocoFail = 0; $chocoSkip = 0
if (Get-Command choco -ErrorAction SilentlyContinue) {
    try {
        $outdated = choco outdated --limit-output 2>&1
        $packages = @()
        foreach ($line in $outdated) {
            if ($line -match '^([^|]+)\|') {
                $name = $matches[1].Trim()
                if (Test-Excluded -Id $name -Name $name) {
                    Write-Log "Excluded: $name" 'SKIP'
                    $chocoSkip++
                } else {
                    $packages += $name
                }
            }
        }

        if ($packages.Count -eq 0) {
            Write-Log 'No Chocolatey updates to apply' 'INFO'
        } else {
            Write-Log "Found $($packages.Count) Chocolatey package(s) to update" 'INFO'
            for ($i = 0; $i -lt $packages.Count; $i++) {
                $pkg = $packages[$i]
                $pct = [math]::Round((($i + 1) / $packages.Count) * 100)
                Write-Progress -Activity 'Updating Chocolatey' -Status "[$($i+1)/$($packages.Count)] $pkg" -PercentComplete $pct
                Write-Host "  [$($i+1)/$($packages.Count)] $pkg..." -ForegroundColor Gray -NoNewline

                $r = Invoke-WithTimeout -TimeoutSeconds $TimeoutChocoPkg -Script {
                    param($name, $to)
                    $out = choco upgrade $name -y --no-progress --timeout=$to --execution-timeout=$to 2>&1 | Out-String
                    [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
                } -ArgumentList $pkg, $TimeoutChocoPkg

                $cText = if ($r.Result) { $r.Result.Output } else { '' }
                $cCode = if ($r.Result) { [int]$r.Result.ExitCode } else { -1 }

                if ($r.TimedOut) {
                    Write-Host " TIMEOUT" -ForegroundColor Yellow
                    Write-Log "choco TIMEOUT: $pkg" 'WARN'
                    $chocoFail++
                } elseif ($cCode -eq 0 -or $cCode -eq 1641 -or $cCode -eq 3010) {
                    # 0 = ok, 1641/3010 = reboot required
                    Write-Host " OK" -ForegroundColor Green
                    Write-Log "choco OK: $pkg (exit $cCode)" 'OK'
                    $chocoSuccess++
                } elseif ($cText -match 'Nothing to do|is the latest version|already installed') {
                    Write-Host " OK (already newest)" -ForegroundColor Green
                    Write-Log "choco OK: $pkg (already newest)" 'OK'
                    $chocoSuccess++
                } else {
                    Write-Host " FAIL (exit $cCode)" -ForegroundColor Yellow
                    Write-Log "choco FAIL: $pkg (exit $cCode)" 'WARN'
                    $chocoFail++
                }
            }
            Write-Progress -Activity 'Updating Chocolatey' -Completed
        }
    } catch {
        Write-Log "Chocolatey failed: $_" 'ERROR'
    }
} else {
    Write-Log 'Chocolatey not installed' 'WARN'
}
$summary['Chocolatey'] = "$chocoSuccess ok, $chocoFail fail, $chocoSkip skipped"

# ===== Step 5: Launch Discord/Battle.net =====================================
Write-Step $steps[4]

# Discord re-adds itself to Windows startup every time it launches via its
# updater. Disable it in Discord's own settings.json (so the launch below does
# NOT re-enable it) and strip any existing Run key. This is durable: Discord
# reads OPEN_ON_STARTUP on launch and keeps startup off.
function Disable-DiscordStartup {
    $settingsPath = Join-Path $env:APPDATA 'discord\settings.json'
    if (Test-Path $settingsPath) {
        try {
            $json = Get-Content $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'OPEN_ON_STARTUP') {
                $json.OPEN_ON_STARTUP = $false
            } else {
                $json | Add-Member -NotePropertyName 'OPEN_ON_STARTUP' -NotePropertyValue $false -Force
            }
            $json | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8
            Write-Log 'Discord startup disabled in settings.json' 'OK'
        } catch {
            Write-Log "Could not update Discord settings.json: $_" 'WARN'
        }
    }
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Get-ItemProperty -Path $runKey -Name 'Discord' -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runKey -Name 'Discord' -ErrorAction SilentlyContinue
            Write-Log 'Removed Discord Run registry key' 'OK'
        }
    } catch {}
}
Disable-DiscordStartup

$otherApps = @(
    @{ Name = 'Discord';    Path = "$env:LOCALAPPDATA\Discord\Update.exe"; Args = '--processStart Discord.exe' },
    @{ Name = 'Battle.net'; Path = "$pf86\Battle.net\Battle.net Launcher.exe"; Args = $null }
)
$launched2 = 0
foreach ($app in $otherApps) {
    if (Test-Path $app.Path) {
        try {
            if ($app.Args) { Start-Process -FilePath $app.Path -ArgumentList $app.Args -ErrorAction Stop }
            else           { Start-Process -FilePath $app.Path -ErrorAction Stop }
            Write-Log "$($app.Name) launched" 'OK'
            $launched2++
        } catch { Write-Log "$($app.Name) launch failed: $_" 'WARN' }
    } else { Write-Log "$($app.Name) not installed" 'SKIP' }
}
$summary['Other apps launched'] = $launched2

# ===== Step 6: Windows Updates ===============================================
Write-Step $steps[5]
try {
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Host "  Installing PSWindowsUpdate..." -ForegroundColor Gray
        Install-PackageProvider NuGet -Force -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
    }
    Import-Module PSWindowsUpdate -ErrorAction Stop

    Write-Host "  Scanning + installing (up to $([int]($TimeoutWindowsUpd/60)) min)..." -ForegroundColor Gray
    $r = Invoke-WithTimeout -TimeoutSeconds $TimeoutWindowsUpd -Activity 'Windows Updates' -ShowProgress -Script {
        Import-Module PSWindowsUpdate
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Continue | Out-String
    }
    if ($r.TimedOut) {
        Write-Log "Windows Update timed out after $TimeoutWindowsUpd s" 'WARN'
        $summary['Windows Update'] = 'timeout'
    } else {
        Write-Log 'Windows Update completed' 'OK'
        $summary['Windows Update'] = 'ok'
    }
} catch {
    Write-Log "Windows Update failed: $_" 'ERROR'
    $summary['Windows Update'] = 'error'
}

# ===== Step 7: Defender signatures ==========================================
Write-Step $steps[6]
if ($RunDefenderUpdate) {
    try {
        $mp = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
        if (Test-Path $mp) {
            & $mp -SignatureUpdate 2>&1 | Out-Null
            Write-Log 'Defender signatures updated' 'OK'
            $summary['Defender'] = 'ok'
        } else {
            Write-Log 'MpCmdRun.exe not found' 'SKIP'
            $summary['Defender'] = 'not found'
        }
    } catch {
        Write-Log "Defender update failed: $_" 'WARN'
        $summary['Defender'] = 'error'
    }
} else {
    Write-Log 'Defender update disabled' 'SKIP'
    $summary['Defender'] = 'disabled'
}

# ---- Summary ---------------------------------------------------------------
$duration = (Get-Date) - $startTime
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Completed in $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "----------------------------------------" -ForegroundColor Green
foreach ($k in $summary.Keys) {
    "{0,-22} : {1}" -f $k, $summary[$k] | Write-Host -ForegroundColor Gray
}
Write-Host "----------------------------------------" -ForegroundColor Green
Write-Host "  Log: $logFile"        -ForegroundColor Gray
if ($StartTranscript) { Write-Host "  Transcript: $transcriptFile" -ForegroundColor Gray }
Write-Host "========================================`n" -ForegroundColor Green

if ($StartTranscript) { try { Stop-Transcript | Out-Null } catch {} }

Write-Host 'Press Enter to exit...' -ForegroundColor Yellow
Read-Host | Out-Null
