# Build-Installer.ps1
# Builds the release exe (unless -SkipCargoBuild) and compiles the Inno Setup
# installer to dist\Upkeep-Setup.exe.

[CmdletBinding()]
param(
    [switch]$SkipCargoBuild
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $SkipCargoBuild) {
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (-not (Test-Path $cargo)) { throw "cargo not found at $cargo" }
    Write-Host '[build] cargo build --release...'
    Push-Location (Join-Path $root 'gui')
    try {
        & $cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

$exe = Join-Path $root 'gui\target\release\Upkeep.exe'
if (-not (Test-Path $exe)) { throw "GUI exe not found: $exe" }

# Locate ISCC (Inno Setup 6): PATH, per-user install, then machine-wide
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    $iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw 'ISCC.exe (Inno Setup 6) not found. Install with: winget install JRSoftware.InnoSetup' }

New-Item -ItemType Directory -Path (Join-Path $root 'dist') -Force | Out-Null

Write-Host "[build] Compiling installer with $iscc..."
& $iscc (Join-Path $root 'installer\Upkeep.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $root 'dist\Upkeep-Setup.exe'
$size = '{0:N1} MB' -f ((Get-Item $setup).Length / 1MB)
Write-Host "[build] Installer: $setup ($size)"
