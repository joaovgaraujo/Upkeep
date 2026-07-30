<#
.SYNOPSIS
    Fully automated "clean" NVIDIA driver update - what NVCleanstall's
    Recommended preset does, without its GUI: query NVIDIA's driver service
    for the newest Game Ready (DCH) driver, download it, extract ONLY the
    core components (no GeForce Experience, no telemetry, no bundled extras),
    and run NVIDIA's own installer silently with no reboot.

.DESCRIPTION
    Components kept: Display.Driver, NVI2 (installer core), EULA.txt,
    ListDevices.txt, setup.cfg, setup.exe. Everything else (GFExperience,
    NVApp, PhysX, ShadowPlay, Telemetry, USBC, audio) is not extracted.
    HD audio can be kept with -KeepAudio (needed for sound over HDMI/DP).

    Requires 7-Zip to unpack the driver package (autodiscovered; installed
    via winget if missing). Downloads land in tools\nvidia\ next to this
    script.

.PARAMETER Install
    Actually run the silent install after extracting. Without it, the
    script only downloads + extracts and tells you the setup path.

.PARAMETER KeepAudio
    Also extract HDAudio (sound over HDMI/DisplayPort).

.PARAMETER DryRun
    Only query and print what would be downloaded.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$KeepAudio,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# 1. Find the newest driver via NVIDIA's AjaxDriverService.
#    GeForce drivers are unified: one package covers all supported GPUs, so a
#    fixed recent product id works regardless of the exact card. osID 57 =
#    Windows 10/11 64-bit, dch=1 = modern driver type.
# ---------------------------------------------------------------------------
$lookup = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
    '?func=DriverManualLookup&psid=127&pfid=995&osID=57&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1'

Write-Output "[nvidia] Querying NVIDIA for the newest Game Ready driver..."
$resp = Invoke-RestMethod -Uri $lookup
$driver = $resp.IDS[0].downloadInfo
if (-not $driver -or -not $driver.DownloadURL) { throw "NVIDIA lookup returned no driver." }
$version = $driver.Version
$url = [uri]::UnescapeDataString($driver.DownloadURL)
Write-Output "[nvidia] Newest driver: $version"
Write-Output "[nvidia] Package: $url"

# Installed version for comparison (DisplayDriver "32.0.15.7688" -> "576.88").
try {
    $raw = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } |
        Select-Object -First 1).DriverVersion
    if ($raw) {
        $digits = ($raw -replace '\.', '')
        $current = "{0}.{1}" -f $digits.Substring($digits.Length - 5, 3), $digits.Substring($digits.Length - 2, 2)
        Write-Output "[nvidia] Installed driver: $current"
        if ($current -eq $version) {
            Write-Output "[nvidia] Already up to date."
            if (-not $DryRun) { exit 0 }
        }
    }
} catch {}

if ($DryRun) {
    Write-Output "[nvidia] [dry-run] Would download, extract core components and $(if ($Install) { 'silently install' } else { 'prepare' }) $version."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Download.
# ---------------------------------------------------------------------------
$workDir = Join-Path $PSScriptRoot 'tools\nvidia'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$pkg = Join-Path $workDir ("nvidia_{0}.exe" -f $version)
if (-not (Test-Path $pkg) -or (Get-Item $pkg).Length -lt 100MB) {
    Write-Output "[nvidia] Downloading (~700 MB, this takes a while)..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $pkg
    $ProgressPreference = 'Continue'
}
Write-Output ("[nvidia] Package ready: {0:N0} MB" -f ((Get-Item $pkg).Length / 1MB))

# ---------------------------------------------------------------------------
# 3. Extract only the clean core with 7-Zip.
# ---------------------------------------------------------------------------
$sevenZip = @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenZip) {
    Write-Output "[nvidia] 7-Zip not found - installing via winget..."
    & winget install --id 7zip.7zip -e --accept-package-agreements --accept-source-agreements --silent
    $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"
    if (-not (Test-Path $sevenZip)) { throw "7-Zip could not be installed." }
}

$extractDir = Join-Path $workDir ("extracted_{0}" -f $version)
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
$components = @('Display.Driver', 'NVI2', 'EULA.txt', 'ListDevices.txt', 'setup.cfg', 'setup.exe')
if ($KeepAudio) { $components += 'HDAudio' }
Write-Output "[nvidia] Extracting core components: $($components -join ', ')"
& $sevenZip x -bso0 -bsp0 "-o$extractDir" $pkg $components
if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed (exit $LASTEXITCODE)." }

# Drop the telemetry/EULA download references NVCleanstall also strips; the
# installer works without them and phones home less.
$cfg = Join-Path $extractDir 'setup.cfg'
if (Test-Path $cfg) {
    $lines = Get-Content $cfg
    $filtered = $lines | Where-Object {
        $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile'
    }
    if ($filtered.Count -lt $lines.Count) {
        $filtered | Set-Content $cfg -Encoding UTF8
        Write-Output "[nvidia] setup.cfg: removed $($lines.Count - $filtered.Count) telemetry/EULA download reference(s)."
    }
}

$setup = Join-Path $extractDir 'setup.exe'
if (-not (Test-Path $setup)) { throw "setup.exe missing after extraction." }

# ---------------------------------------------------------------------------
# 4. Install silently (NVIDIA's own installer switches), or hand over.
# ---------------------------------------------------------------------------
if ($Install) {
    Write-Output "[nvidia] Installing $version silently (no reboot). Screen may flicker."
    $proc = Start-Process -FilePath $setup -ArgumentList @('-s', '-noreboot') -Wait -PassThru
    Write-Output "[nvidia] Installer finished (exit code $($proc.ExitCode); 0 = ok, 1 = reboot required)."
    exit $proc.ExitCode
} else {
    Write-Output "[nvidia] Clean driver prepared. To install:"
    Write-Output "[nvidia]   `"$setup`" -s -noreboot"
    Write-Output "[nvidia] (or run this script with -Install)"
}
