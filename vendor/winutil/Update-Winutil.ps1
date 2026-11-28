<#
.SYNOPSIS
    Moves the pinned winutil in vendor\winutil to another release.

.DESCRIPTION
    Downloads winutil.ps1 and LICENSE for the given release tag (default: the
    latest GitHub release), writes vendor\winutil\pin.json with its SHA-256,
    then runs tests\Winutil.Tests.ps1. Those tests fail if a tweak ID Upkeep
    uses was renamed or removed, if a registry toggle Setup-NewPC.ps1 mirrors
    changed, or if a used tweak started calling DISM. Fix those before
    committing the new pin.

.EXAMPLE
    .\vendor\winutil\Update-Winutil.ps1
.EXAMPLE
    .\vendor\winutil\Update-Winutil.ps1 -Tag 26.11.13
#>
[CmdletBinding()]
param([string]$Tag)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir = Join-Path $repo 'vendor\winutil'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

if (-not $Tag) {
    $Tag = (Invoke-RestMethod 'https://api.github.com/repos/ChrisTitusTech/winutil/releases/latest' -TimeoutSec 60).tag_name
}
$source = "https://github.com/ChrisTitusTech/winutil/releases/download/$Tag/winutil.ps1"
$file = Join-Path $dir 'winutil.ps1'
Write-Output "Downloading winutil $Tag from $source"
Invoke-WebRequest -Uri $source -OutFile $file -UseBasicParsing -TimeoutSec 120
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ChrisTitusTech/winutil/$Tag/LICENSE" -OutFile (Join-Path $dir 'LICENSE') -UseBasicParsing -TimeoutSec 60

$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
$pin = [ordered]@{ Version = $Tag; Source = $source; Sha256 = $hash }
Set-Content -LiteralPath (Join-Path $dir 'pin.json') -Value (ConvertTo-Json -InputObject $pin) -Encoding ASCII
Write-Output "Pinned winutil $Tag ($hash)."

Import-Module Pester -MinimumVersion 5.0.0
$result = Invoke-Pester -Path (Join-Path $repo 'tests\Winutil.Tests.ps1') -PassThru -Output Detailed
if ($result.FailedCount -gt 0) {
    Write-Output "winutil $Tag does not line up with Upkeep in $($result.FailedCount) place(s). Fix them before committing."
    exit 1
}
Write-Output "winutil $Tag lines up with everything Upkeep uses."
