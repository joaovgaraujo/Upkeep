<#
.SYNOPSIS
    Downloads the portable NVCleanstall from TechPowerUp (no install needed),
    saves it under tools\ next to this script, writes its path into
    settings.json as NVCleanPath, and optionally opens it.

.DESCRIPTION
    TechPowerUp has no static download URL: the page requires two POSTs
    (file id, then mirror id) that answer with a signed, expiring file URL.
    This script replays that flow, always fetching the newest listed version.

.PARAMETER Open
    Launch NVCleanstall after downloading.
#>
[CmdletBinding()]
param(
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
$page = 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/'

$toolsDir = Join-Path $PSScriptRoot 'tools'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
$exePath = Join-Path $toolsDir 'NVCleanstall.exe'

Write-Output "[nvclean] Looking up the newest NVCleanstall version..."
$html = (Invoke-WebRequest -Uri $page -UserAgent $ua -UseBasicParsing).Content

# Newest file id = the first download form on the page.
$idMatch = [regex]::Match($html, 'name="id" value="(\d+)"')
$verMatch = [regex]::Match($html, 'NVCleanstall_([\d.]+)\.exe')
if (-not $idMatch.Success) { throw "Could not find a download id on $page" }
$fileId = $idMatch.Groups[1].Value
$version = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { '?' }
Write-Output "[nvclean] Newest version: $version (file id $fileId)"

# POST 1: choose the file -> mirror page. POST 2: choose a mirror -> 302 to
# the signed file URL (Invoke-WebRequest follows it).
$step2 = Invoke-WebRequest -Uri $page -Method Post -Body @{ id = $fileId } `
    -UserAgent $ua -Headers @{ Referer = $page } -UseBasicParsing
$serverMatch = [regex]::Match($step2.Content, 'name="server_id" value="(\d+)"')
if (-not $serverMatch.Success) { throw "Could not find a mirror id" }
$serverId = $serverMatch.Groups[1].Value

Write-Output "[nvclean] Downloading from mirror $serverId..."
Invoke-WebRequest -Uri $page -Method Post -Body @{ id = $fileId; server_id = $serverId } `
    -UserAgent $ua -Headers @{ Referer = $page } -OutFile $exePath -UseBasicParsing

$size = (Get-Item $exePath).Length
if ($size -lt 1MB) { throw "Download looks wrong ($size bytes) - aborting." }
Write-Output ("[nvclean] Saved: {0} ({1:N1} MB)" -f $exePath, ($size / 1MB))

# Record the path in settings.json (preserving other keys).
$settingsPath = Join-Path $PSScriptRoot 'settings.json'
$settings = if (Test-Path $settingsPath) {
    Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}
if ($settings.PSObject.Properties['NVCleanPath']) {
    $settings.NVCleanPath = $exePath
} else {
    $settings | Add-Member -NotePropertyName 'NVCleanPath' -NotePropertyValue $exePath
}
$settings | ConvertTo-Json -Depth 8 | Set-Content -Path $settingsPath -Encoding UTF8
Write-Output "[nvclean] settings.json updated (NVCleanPath)."

if ($Open) { Start-Process -FilePath $exePath }
