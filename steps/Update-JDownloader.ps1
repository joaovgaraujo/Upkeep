# Update-JDownloader.ps1
# Runs a bounded JDownloader 2 self-update pass without opening the full GUI.
# Mechanism (verified against the JDownloader source mirror):
#   - Launch the bundled JRE with "-jar JDownloader.jar -update -norestart" and
#     JVM headless mode. The update check/apply happens in the first seconds of
#     startup; there is NO update-then-exit signal, so we bound the run ourselves.
#   - If JDownloader is already running, a new launch just forwards its args over
#     IPC to the existing instance and exits (no update, ambiguous exit code) -
#     in that case we skip; an open JD self-updates on its own 10-minute cycle.
#   - Success detection: build.json content diff + new files in logs\updatehistory\.
# Output lines are prefixed [jdownloader]. Exit 0 = ok/no-op, 1 = tool missing.

[CmdletBinding()]
param(
    # Empty = autodiscover across the known install locations (the official
    # installer commonly installs per-user to %LOCALAPPDATA%\JDownloader 2.0).
    [string]$JDownloaderPath = '',

    # The community-standard bound; real updates complete within seconds.
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'

if (-not $JDownloaderPath) {
    foreach ($candidate in @(
        'C:\Program Files\JDownloader'
        'C:\Program Files (x86)\JDownloader'
        (Join-Path $env:LOCALAPPDATA 'JDownloader 2.0')
        (Join-Path $env:USERPROFILE 'JDownloader 2.0')
    )) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'JDownloader.jar')) {
            $JDownloaderPath = $candidate
            break
        }
    }
    if (-not $JDownloaderPath) {
        Write-Host '[jdownloader] Not found in any known location - skipping.'
        exit 0
    }
}

$java          = Join-Path $JDownloaderPath 'jre\bin\java.exe'
$jar           = Join-Path $JDownloaderPath 'JDownloader.jar'
$buildJson     = Join-Path $JDownloaderPath 'build.json'
$updateHistDir = Join-Path $JDownloaderPath 'logs\updatehistory'

if (-not (Test-Path -LiteralPath $jar)) {
    Write-Host "[jdownloader] Not installed at $JDownloaderPath - skipping."
    exit 0
}
if (-not (Test-Path -LiteralPath $java)) {
    # Fall back to PATH java if the bundled JRE layout ever changes
    $javaCmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($javaCmd) { $java = $javaCmd.Source } else {
        # Exit 2 = "nothing to do here" (see Update-SteamGames.ps1). The
        # sibling skip paths above already exit 0; this one exiting 1 turned
        # the whole Apps category red on a machine with no Java.
        Write-Host '[jdownloader] No Java runtime found (bundled or PATH) - skipping.'
        exit 2
    }
}

if (Get-Process -Name 'JDownloader2' -ErrorAction SilentlyContinue) {
    Write-Host '[jdownloader] Already running - skipping (it self-updates while open).'
    exit 0
}

# One-time idempotent settings tweak: make the updater GUI auto-close when
# there is nothing to show, so unattended passes never leave a window behind.
$updSettings = Join-Path $JDownloaderPath 'cfg\org.jdownloader.updatev2.UpdateSettings.json'
if (Test-Path -LiteralPath $updSettings) {
    try {
        $s = Get-Content -LiteralPath $updSettings -Raw | ConvertFrom-Json
        $changed = $false
        foreach ($k in 'autohideguiiftherearenoupdatesenabled', 'autohideguiifsilentupdateswereinstalledenabled') {
            if (-not $s.$k) {
                # Assigning a property that doesn't exist on a
                # ConvertFrom-Json object THROWS on PS 5.1, and the catch
                # below would swallow it - silently abandoning both settings
                # on a fresh install whose json lacks these keys.
                if ($s.PSObject.Properties.Name -contains $k) {
                    $s.$k = $true
                } else {
                    $s | Add-Member -NotePropertyName $k -NotePropertyValue $true -Force
                }
                $changed = $true
            }
        }
        # WriteAllText, not Set-Content -Encoding UTF8: the latter emits a
        # UTF-8 BOM on PS 5.1, and a leading U+FEFF makes a strict JSON
        # parser reject the whole file.
        if ($changed) {
            [IO.File]::WriteAllText($updSettings, ($s | ConvertTo-Json -Depth 10))
        }
    } catch { Write-Host "[jdownloader] UpdateSettings patch failed: $($_.Exception.Message)" }
}

$beforeBuild = if (Test-Path -LiteralPath $buildJson) { Get-Content -LiteralPath $buildJson -Raw } else { '' }
$beforeHist  = if (Test-Path -LiteralPath $updateHistDir) { (Get-ChildItem -LiteralPath $updateHistDir -File).Count } else { 0 }

Write-Host "[jdownloader] Running bounded self-update pass (max ${TimeoutSec}s)..."
$proc = Start-Process -FilePath $java `
    -ArgumentList '-Djava.awt.headless=true', '-jar', "`"$jar`"", '-update', '-norestart' `
    -WorkingDirectory $JDownloaderPath -WindowStyle Hidden -PassThru

if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    # The updater may have self-restarted into a NEW pid; stop the original,
    # then any java/javaw process rooted in the JDownloader folder.
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process java, javaw -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$JDownloaderPath*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[jdownloader] Bounded window elapsed - updater terminated."
}

Start-Sleep -Seconds 1
$afterBuild = if (Test-Path -LiteralPath $buildJson) { Get-Content -LiteralPath $buildJson -Raw } else { '' }
$afterHist  = if (Test-Path -LiteralPath $updateHistDir) { (Get-ChildItem -LiteralPath $updateHistDir -File).Count } else { 0 }

if ($afterBuild -ne $beforeBuild -or $afterHist -gt $beforeHist) {
    Write-Host '[jdownloader] Update applied (build.json changed / new updatehistory log).'
} else {
    Write-Host '[jdownloader] No update applied (already current).'
}
exit 0
