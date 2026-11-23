# Build-Portable.ps1
# Assembles a self-contained portable folder + zip in dist\:
#   Upkeep.exe   (Rust GUI, single exe)
#   SystemUpdate_Topgrade.bat (update engine)
#   steps\                    (Store / Steam / JDownloader step scripts)
#   apps.json + presets\ + Install-Apps.ps1 + Export-InstalledApps.ps1
#   README-PORTABLE.md
# The exe locates its root by finding SystemUpdate_Topgrade.bat next to itself,
# so the folder works from any location (USB stick, second machine).
# settings.json is created on first run with autodiscovered tool paths.

[CmdletBinding()]
param(
    [switch]$SkipCargoBuild,
    [switch]$NoZip,
    # Builds the version that never asks for administrator rights instead:
    # dist\Upkeep-NoAdmin\Upkeep-NoAdmin.exe (cargo feature "portable",
    # asInvoker manifest) and dist\Upkeep-NoAdmin.zip. Its own target dir
    # keeps the two exes from overwriting each other.
    [switch]$NoAdmin
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- 1. Build the GUI exe ---
# PATH first so CI runners (and anyone with a non-default CARGO_HOME) work;
# the profile path is the fallback for a plain local rustup install.
$cargo = (Get-Command cargo -ErrorAction SilentlyContinue).Source
if (-not $cargo) { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
$targetDir = if ($NoAdmin) { 'gui\target\noadmin' } else { 'gui\target' }
$exe = Join-Path $root "$targetDir\release\Upkeep.exe"
$exeName = if ($NoAdmin) { 'Upkeep-NoAdmin.exe' } else { 'Upkeep.exe' }
$distName = if ($NoAdmin) { 'Upkeep-NoAdmin' } else { 'Upkeep' }
if (-not $SkipCargoBuild) {
    if (-not (Test-Path $cargo)) { throw "cargo not found on PATH or at $cargo" }
    Write-Host '[build] cargo build --release...'
    Push-Location (Join-Path $root 'gui')
    try {
        if ($NoAdmin) {
            & $cargo build --release --locked --features portable --target-dir (Join-Path $root $targetDir)
        } else {
            & $cargo build --release --locked
        }
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }
}
if (-not (Test-Path $exe)) { throw "GUI exe not found: $exe" }

# --- 2. Assemble dist folder ---
$dist = Join-Path $root "dist\$distName"
$dist = [IO.Path]::GetFullPath($dist)
$distRoot = [IO.Path]::GetFullPath((Join-Path $root 'dist')).TrimEnd('\') + '\'
if (-not $dist.StartsWith($distRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Portable output must stay inside $distRoot"
}
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dist 'steps') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dist 'presets') -Force | Out-Null

Copy-Item $exe (Join-Path $dist $exeName)
Copy-Item (Join-Path $root 'SystemUpdate_Topgrade.bat') $dist
Copy-Item (Join-Path $root 'steps\*.ps1') (Join-Path $dist 'steps')
Copy-Item (Join-Path $root 'apps.json') $dist
Copy-Item (Join-Path $root 'skill-sources.json') $dist
Copy-Item (Join-Path $root 'presets\*.json') (Join-Path $dist 'presets')
Copy-Item (Join-Path $root 'presets\*.cfg') (Join-Path $dist 'presets')
Copy-Item (Join-Path $root 'Install-Apps.ps1') $dist
Copy-Item (Join-Path $root 'Export-InstalledApps.ps1') $dist
Copy-Item (Join-Path $root 'Setup-NewPC.ps1') $dist
Copy-Item (Join-Path $root 'Repair-Usb4Driver.ps1') $dist
Copy-Item (Join-Path $root 'Export-StartupReport.ps1') $dist
Copy-Item (Join-Path $root 'Get-NVCleanstall.ps1') $dist
Copy-Item (Join-Path $root 'Get-NvidiaDriver.ps1') $dist
# boot-times.json is optional and NOT in the repo: it holds startup timings
# measured on one specific machine, which is both personal data and misleading
# to ship as though it described someone else's PC. Copy it if the user has
# made their own; the Startup page's Time column just stays blank without it.
$bootTimes = Join-Path $root 'boot-times.json'
if (Test-Path $bootTimes) { Copy-Item $bootTimes $dist }

$readme = @'
# Upkeep - Portable

Run **Upkeep.exe** (UAC prompt appears once - the engine inherits
elevation). Pick categories, hit Run; progress streams inline, nothing opens
a second console.

Contents:
- Upkeep.exe - the dashboard (single exe, no install)
- SystemUpdate_Topgrade.bat - the update engine (also runnable standalone)
- steps\ - Store / Steam games / JDownloader update steps
- Install-Apps.ps1 + apps.json + presets\ - new-PC app installer
  (e.g.: powershell -ExecutionPolicy Bypass -File Install-Apps.ps1 -Preset new-pc-basic)
- Setup-NewPC.ps1 - one-shot new-PC setup (restore point, winutil tweaks,
  toggles, SDIO/NVCleanstall drivers, O&O ShutUp10++, essentials apps);
  driven from the "New PC" and "Optimize" pages in the GUI
- settings.json - created on first run; tool paths (SDIO, NVCleanstall, ...)
  are autodiscovered and can be edited here

Notes:
- Excluded/pinned apps (Adobe Acrobat, etc.) are managed in the Pins tab.
- NVCleanstall "Recommended Update": build a package once in its GUI
  (Recommended preset + Disable Installer Telemetry + Unattended Express),
  save the exe path into settings.json as NVCleanPackagePath - after that
  the button runs it unattended with -y -noreboot.
- Unsigned exe: SmartScreen may warn on first run on a new machine.
'@
if ($NoAdmin) {
    $readme = @'
# Upkeep - no administrator rights

Run **Upkeep-NoAdmin.exe**. It never shows a UAC prompt, so it works on a PC
where your account is not an administrator. It updates what your Windows
account can update by itself:

- winget apps installed for your account only (machine-wide apps with
  updates are named in the log and left alone)
- Microsoft Store apps, Steam games, JDownloader
- language tools and extensions through topgrade (rustup, pip, uv, pnpm,
  VS Code extensions, gh extensions, MiKTeX), Claude Code and Codex, skills

It skips everything that needs administrator rights: Windows Update and the
26H2 step, Chocolatey, machine-wide apps, G HUB, RustDesk, restoring startup
services, and the Install, New PC, Optimize and Startup & Services pages. An
installer that asks for elevation fails instead of prompting.

Settings and logs go to your own profile (AppData and Documents), as with
the installed version.
'@
}
Set-Content -Path (Join-Path $dist 'README-PORTABLE.md') -Value $readme -Encoding UTF8

# --- 3. Zip ---
if (-not $NoZip) {
    $zip = Join-Path $root $(if ($NoAdmin) { 'dist\Upkeep-NoAdmin.zip' } else { 'dist\Upkeep-Portable.zip' })
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $dist -DestinationPath $zip
    $zipSize = '{0:N1} MB' -f ((Get-Item $zip).Length / 1MB)
    Write-Host "[build] Portable zip: $zip ($zipSize)"
}

Write-Host "[build] Portable folder: $dist"
Get-ChildItem $dist -Recurse -File | ForEach-Object {
    Write-Host ("  {0,10:N0}  {1}" -f $_.Length, $_.FullName.Substring($dist.Length + 1))
}
