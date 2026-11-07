<#
.SYNOPSIS
    Checks, at the end of an update run, whether NVIDIA has a newer GPU
    driver than the one installed, and points at NVCleanstall when it does.

.DESCRIPTION
    No other step updates the GPU driver: Windows Update offers old NVIDIA
    builds or none, and winget does not carry the Game Ready driver. On
    2026-11-07 this PC had 621.01 while NVIDIA's newest was 621.14, and no
    run said so. This runs Get-NvidiaDriver.ps1 -DryRun (query only, nothing
    downloaded) and, when a newer driver exists, lists it at the end of the
    run. The dashboard shows an "Open NVCleanstall" button for it.
    Installing stays your call: a driver install blanks the screen and can
    need a restart.

.NOTES
    Exit codes: 0 = current or listed; 2 = no NVIDIA GPU, or NVIDIA could
    not be reached.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [string]$QueryScript
)
$ErrorActionPreference = 'Continue'
if (-not $QueryScript) { $QueryScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-NvidiaDriver.ps1' }

function Write-Log {
    param([string[]]$Lines)
    $Lines | Write-Host
    if ($LogFile) { try { $Lines | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}

$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
$manualPath = Join-Path $reportDir 'manual-updates-nvidia.json'
Remove-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue

$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }) | Select-Object -First 1
if (-not $gpu) { exit 2 }
if (-not (Test-Path -LiteralPath $QueryScript)) { Write-Log "[nvidia] Driver check unavailable: $QueryScript is missing."; exit 2 }

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $QueryScript -DryRun 2>&1 | Out-String
$newest = [regex]::Match($out, 'Newest driver:\s*(\d+\.\d+)').Groups[1].Value
$installed = [regex]::Match($out, 'Installed driver:\s*(\d+\.\d+)').Groups[1].Value
if (-not $newest -or -not $installed) {
    Write-Log "[nvidia] Could not check for a newer driver for $($gpu.Name) (NVIDIA's driver service did not answer)."
    exit 2
}
if ([version]$newest -le [version]$installed) {
    Write-Log "[nvidia] $($gpu.Name): driver $installed is the newest."
    exit 0
}
Write-Log "[nvidia] Driver update available: $installed -> $newest ($($gpu.Name)). Open NVCleanstall to install it without the extras."
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
ConvertTo-Json -Depth 3 -InputObject @([pscustomobject]@{
        Source = 'nvidia'; Id = 'NVIDIA driver'; Name = "NVIDIA driver ($($gpu.Name))"
        Current = $installed; Available = $newest
        Reason = 'Upkeep does not install GPU drivers on its own: the screen goes blank and it can need a restart'
        Fix = 'Open NVCleanstall (Tools > Drivers, or the button under the results), or use "Clean NVIDIA driver update" there.'
    }) | Set-Content -LiteralPath $manualPath -Encoding UTF8
exit 0
