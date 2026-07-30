# Update-SteamGames.ps1
# Makes Steam update every installed game unattended. Steam has no "update all"
# CLI/URL, so the working mechanism (community-established) is:
#   1. Shut Steam down cleanly (steam.exe -shutdown).
#   2. In every appmanifest_*.acf across all library folders: set StateFlags to 6
#      ("Update Required + Fully Installed") and AutoUpdateBehavior to 0 ("always
#      keep updated"), so the client checks and schedules everything immediately.
#   3. Relaunch steam.exe -silent (tray only, no window).
#   4. Wait for completion: per-app registry flag HKCU\Software\Valve\Steam\Apps\<id>\Updating
#      plus the steamapps\downloading staging folder, with a debounce (idle twice
#      in a row) because there is a gap between login and the first download.
# Output lines are prefixed [steam]. Exit 0 = ok/idle, 1 = Steam not found.

[CmdletBinding()]
param(
    # Empty = autodiscover (registry InstallPath, then the default location).
    [string]$SteamPath = '',

    # Big game updates can take a long time; when the budget runs out we leave
    # Steam downloading in the background rather than killing it.
    [int]$TimeoutMin = 60,

    # Seconds to let Steam log in and start scheduling before we begin polling.
    [int]$StartupGraceSec = 60
)

$ErrorActionPreference = 'Continue'

if (-not $SteamPath) {
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
        if ($reg -and $reg.InstallPath -and (Test-Path -LiteralPath (Join-Path $reg.InstallPath 'steam.exe'))) {
            $SteamPath = $reg.InstallPath
        }
    } catch { }
    if (-not $SteamPath) { $SteamPath = 'C:\Program Files (x86)\Steam' }
}

$steamExe = Join-Path $SteamPath 'steam.exe'
if (-not (Test-Path -LiteralPath $steamExe)) {
    # Exit 2 = "nothing to do here", NOT a failure. Exiting 1 made the engine
    # report STEAM_STATUS=error, so a PC without Steam showed a red Steam chip
    # and "finished with issues" on every single run.
    Write-Host "[steam] steam.exe not found at $SteamPath - skipping."
    exit 2
}

# --- Collect every library folder (games can live on multiple drives) ---
$libraries = [System.Collections.Generic.List[string]]::new()
$mainApps = Join-Path $SteamPath 'steamapps'
if (Test-Path -LiteralPath $mainApps) { $libraries.Add($mainApps) }

$libVdf = Join-Path $mainApps 'libraryfolders.vdf'
if (Test-Path -LiteralPath $libVdf) {
    # "path"  "D:\\SteamLibrary" entries; VDF escapes backslashes
    $vdfText = Get-Content -LiteralPath $libVdf -Raw
    foreach ($m in [regex]::Matches($vdfText, '"path"\s+"([^"]+)"')) {
        $lib = ($m.Groups[1].Value -replace '\\\\', '\')
        $apps = Join-Path $lib 'steamapps'
        if ((Test-Path -LiteralPath $apps) -and -not $libraries.Contains($apps)) {
            $libraries.Add($apps)
        }
    }
}
Write-Host "[steam] Library folders: $($libraries -join '; ')"

# --- 1. Shut Steam down cleanly ---
if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
    Write-Host '[steam] Shutting down running Steam client...'
    Start-Process -FilePath $steamExe -ArgumentList '-shutdown'
    $shutdownDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Process -Name steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $shutdownDeadline) {
        Start-Sleep -Seconds 2
    }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        # A real failure, not a skip: no game was flagged and nothing will be
        # updated this run. Exiting 0 here reported "Steam games : ok" for a
        # pass that did precisely nothing.
        Write-Host '[steam] Steam did not exit within 60s - skipping ACF edits to avoid corruption.'
        exit 1
    }
}

# --- 2. Flag every installed game for an update check ---
$appIds = @()
foreach ($lib in $libraries) {
    foreach ($acf in Get-ChildItem -Path $lib -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
        if ($acf.Name -match 'appmanifest_(\d+)\.acf') { $appIds += $Matches[1] }
        try {
            $content = Get-Content -LiteralPath $acf.FullName -Raw
            $content = $content -replace '"StateFlags"\s+"\d+"', '"StateFlags"		"6"'
            $content = $content -replace '"AutoUpdateBehavior"\s+"\d+"', '"AutoUpdateBehavior"		"0"'
            Set-Content -LiteralPath $acf.FullName -Value $content -NoNewline -Encoding UTF8
        }
        catch {
            Write-Host "[steam] Could not patch $($acf.Name): $($_.Exception.Message)"
        }
    }
}
Write-Host "[steam] Flagged $($appIds.Count) installed games for update check."
if ($appIds.Count -eq 0) {
    Write-Host '[steam] No games installed - nothing to do.'
    exit 0
}

# --- 3. Relaunch Steam quietly ---
Write-Host '[steam] Starting Steam in silent mode...'
Start-Process -FilePath $steamExe -ArgumentList '-silent'
Start-Sleep -Seconds $StartupGraceSec

# --- 4. Poll until idle (debounced) or budget exhausted ---
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$idleStreak = 0
$lastReport = Get-Date

while ((Get-Date) -lt $deadline) {
    $updating = @($appIds | Where-Object {
        (Get-ItemProperty "HKCU:\Software\Valve\Steam\Apps\$_" -ErrorAction SilentlyContinue).Updating -eq 1
    })
    $staging = @()
    foreach ($lib in $libraries) {
        $staging += @(Get-ChildItem -Path (Join-Path $lib 'downloading') -Directory -ErrorAction SilentlyContinue)
    }

    if ($updating.Count -eq 0 -and $staging.Count -eq 0) {
        $idleStreak++
        # Debounce: require two consecutive idle checks (gap between scheduling waves)
        if ($idleStreak -ge 2) {
            Write-Host '[steam] All game updates complete.'
            exit 0
        }
    }
    else {
        $idleStreak = 0
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            Write-Host "[steam] Still updating: $($updating.Count) app(s) flagged, $($staging.Count) staging download(s)..."
            $lastReport = Get-Date
        }
    }
    Start-Sleep -Seconds 15
}

Write-Host "[steam] Time budget of $TimeoutMin minutes reached - downloads continue in the background."
exit 0
