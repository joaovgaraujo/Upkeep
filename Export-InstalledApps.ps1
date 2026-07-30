<#
.SYNOPSIS
    Exports the winget-installed package list on this machine and cross
    references it against apps.json to find apps that are installed but
    not yet cataloged.

.DESCRIPTION
    Runs `winget export` to get a machine-readable list of every winget
    package installed on this PC, maps each entry to the catalog's slug
    format where possible, and prints any winget package ids that are not
    already present as a "winget" value somewhere in apps.json. This is a
    read-only helper to keep the catalog honest over time -- it does not
    modify apps.json itself.

.PARAMETER Catalog
    Path to the catalog JSON file. Defaults to apps.json next to this
    script.

.PARAMETER ExportPath
    Where to write the raw `winget export` JSON. Defaults to
    winget-export.json next to this script.

.EXAMPLE
    powershell -NoProfile -File .\Export-InstalledApps.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Catalog,

    [Parameter()]
    [string]$ExportPath
)

$ErrorActionPreference = 'Stop'

# NOTE: $PSScriptRoot is not reliably populated while parameter default
# values are being evaluated in Windows PowerShell 5.1 when the script
# uses [CmdletBinding()] -- it IS populated once the script body starts
# running, so resolve these defaults here instead of in the param block.
if (-not $Catalog) {
    $Catalog = Join-Path $PSScriptRoot 'apps.json'
}
if (-not $ExportPath) {
    $ExportPath = Join-Path $PSScriptRoot 'winget-export.json'
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Output "ERROR: winget was not found on PATH. Cannot export installed apps."
    exit 1
}

if (-not (Test-Path -LiteralPath $Catalog)) {
    Write-Output "ERROR: Catalog file not found: $Catalog"
    exit 1
}

Write-Output "Exporting installed winget packages..."
& winget export -o $ExportPath --accept-source-agreements | Out-Null

if (-not (Test-Path -LiteralPath $ExportPath)) {
    Write-Output "ERROR: winget export did not produce an output file at $ExportPath"
    exit 1
}

try {
    $exportJson = Get-Content -LiteralPath $ExportPath -Raw | ConvertFrom-Json
} catch {
    Write-Output "ERROR: Failed to parse winget export JSON at $ExportPath"
    Write-Output $_.Exception.Message
    exit 1
}

try {
    $catalogJson = Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json
} catch {
    Write-Output "ERROR: Failed to parse catalog JSON at $Catalog"
    Write-Output $_.Exception.Message
    exit 1
}

# Collect every winget id already known to the catalog (strip any
# "msstore:" prefix so store apps compare cleanly against export ids).
$knownWingetIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($prop in $catalogJson.PSObject.Properties) {
    $wid = $prop.Value.winget
    if ($wid -and $wid -ne 'na') {
        if ($wid -like 'msstore:*') { $wid = $wid.Substring('msstore:'.Length) }
        $null = $knownWingetIds.Add($wid)
    }
}

# Installed packages live under Sources[].Packages[] in winget's export
# format. Each source (winget, msstore) is a separate bucket.
$installedPackages = New-Object System.Collections.Generic.List[object]
foreach ($source in $exportJson.Sources) {
    foreach ($pkg in $source.Packages) {
        $installedPackages.Add([pscustomobject]@{
            PackageIdentifier = $pkg.PackageIdentifier
            Source            = $source.SourceDetails.Name
        })
    }
}

Write-Output "Found $($installedPackages.Count) installed winget package(s) across $($exportJson.Sources.Count) source(s)."
Write-Output ""

$missing = $installedPackages | Where-Object { -not $knownWingetIds.Contains($_.PackageIdentifier) } | Sort-Object PackageIdentifier -Unique

if ($missing.Count -eq 0) {
    Write-Output "Every installed package is already represented in the catalog. Nothing to add."
} else {
    Write-Output "Installed packages NOT present in $Catalog ($($missing.Count)):"
    Write-Output ""
    foreach ($m in $missing) {
        # Suggest a slug: lowercase the part after the last dot in the
        # winget id, kebab-cased. This is a starting point only -- review
        # before adding to apps.json.
        $lastSegment = ($m.PackageIdentifier -split '\.')[-1]
        $suggestedSlug = ($lastSegment -creplace '(?<=[a-z0-9])(?=[A-Z])', '-').ToLowerInvariant()
        $suggestedSlug = $suggestedSlug -replace '[^a-z0-9]+', '-'
        $suggestedSlug = $suggestedSlug.Trim('-')

        Write-Output ("  {0,-45} source={1,-10} suggested-slug={2}" -f $m.PackageIdentifier, $m.Source, $suggestedSlug)
    }
    Write-Output ""
    Write-Output "Review the list above and add entries to $Catalog manually, e.g.:"
    Write-Output '  "<slug>": { "content": "<Name>", "category": "<Category>", "winget": "<Id>", "choco": "na", "description": "<...>" }'
}

Write-Output ""
Write-Output "Raw winget export saved to: $ExportPath"

exit 0
