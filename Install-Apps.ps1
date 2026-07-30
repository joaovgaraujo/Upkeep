<#
.SYNOPSIS
    Installs a curated set of applications on a new PC using winget (or
    chocolatey as an opt-in alternative), driven by apps.json and named
    presets under presets/.

.DESCRIPTION
    Resolves a list of app slugs (either from -Preset, -Apps, or both),
    looks each one up in the catalog (apps.json), and installs whatever
    is not already present. Already-installed apps are detected via
    `winget list --id <id> -e` and skipped. Prints a summary table of
    installed / skipped / failed apps at the end and exits non-zero if
    anything failed.

.PARAMETER Preset
    Name of a preset file under presets/ (without the .json extension),
    e.g. "new-pc-basic", "dev-machine", "full".

.PARAMETER Apps
    Explicit list of catalog slugs to install. Can be combined with
    -Preset; the two lists are merged and de-duplicated.

.PARAMETER Catalog
    Path to the catalog JSON file. Defaults to apps.json next to this
    script.

.PARAMETER DryRun
    Show what would happen without installing anything.

.PARAMETER PreferChoco
    Use chocolatey instead of winget for apps that have a choco package
    (choco field is not "na"). Falls back to winget if choco is "na" or
    choco itself is unavailable.

.EXAMPLE
    powershell -NoProfile -File .\Install-Apps.ps1 -Preset new-pc-basic -DryRun

.EXAMPLE
    powershell -NoProfile -File .\Install-Apps.ps1 -Apps git,vscode,7zip
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Preset,

    [Parameter()]
    [string[]]$Apps,

    [Parameter()]
    [string]$Catalog,

    [switch]$DryRun,

    [switch]$PreferChoco
)

$ErrorActionPreference = 'Stop'

# NOTE: $PSScriptRoot is not reliably populated while parameter default
# values are being evaluated in Windows PowerShell 5.1 when the script
# uses [CmdletBinding()] -- it IS populated once the script body starts
# running, so resolve the Catalog default here instead of in the param
# block.
if (-not $Catalog) {
    $Catalog = Join-Path $PSScriptRoot 'apps.json'
}

# ---------------------------------------------------------------------------
# Self-elevate to administrator (UAC prompt) if not already elevated.
# Mirrors the pattern used in SystemUpdate_Topgrade.bat.
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($DryRun) {
    if (-not (Test-IsAdmin)) {
        Write-Output "Not running as administrator -- continuing anyway because -DryRun makes no changes."
    }
} elseif (-not (Test-IsAdmin)) {
    Write-Output "Not running as administrator. Requesting elevation..."

    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")

    if ($Preset)      { $argList += @('-Preset', "`"$Preset`"") }
    if ($Apps)        { $argList += @('-Apps', ($Apps -join ',')) }
    if ($Catalog)      { $argList += @('-Catalog', "`"$Catalog`"") }
    if ($DryRun)      { $argList += '-DryRun' }
    if ($PreferChoco) { $argList += '-PreferChoco' }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -ErrorAction Stop
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        Write-Output ""
        Write-Output "Elevation was declined or failed. This script requires administrator"
        Write-Output "rights to install system-wide packages. Nothing was changed."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Resolve and validate inputs
# ---------------------------------------------------------------------------
# With `powershell -File`, a value like "a,b,c" binds as ONE string[] element -
# commas are not split. Both the self-elevation re-invocation above (which
# rejoins with commas) and external callers (the dashboard GUI) rely on
# comma-separated form, so normalize here.
if ($Apps) {
    $Apps = @($Apps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if (-not $Preset -and (-not $Apps -or $Apps.Count -eq 0)) {
    Write-Output "ERROR: You must specify -Preset <name> and/or -Apps <slug,slug,...>."
    exit 1
}

if (-not (Test-Path -LiteralPath $Catalog)) {
    Write-Output "ERROR: Catalog file not found: $Catalog"
    exit 1
}

try {
    $catalogJson = Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json
} catch {
    Write-Output "ERROR: Failed to parse catalog JSON at $Catalog"
    Write-Output $_.Exception.Message
    exit 1
}

# Build a case-insensitive slug -> entry lookup
$catalogMap = @{}
foreach ($prop in $catalogJson.PSObject.Properties) {
    $catalogMap[$prop.Name] = $prop.Value
}

$slugs = New-Object System.Collections.Generic.List[string]

if ($Preset) {
    $presetPath = Join-Path $PSScriptRoot (Join-Path 'presets' "$Preset.json")
    if (-not (Test-Path -LiteralPath $presetPath)) {
        Write-Output "ERROR: Preset file not found: $presetPath"
        exit 1
    }
    try {
        $presetSlugs = Get-Content -LiteralPath $presetPath -Raw | ConvertFrom-Json
    } catch {
        Write-Output "ERROR: Failed to parse preset JSON at $presetPath"
        Write-Output $_.Exception.Message
        exit 1
    }
    foreach ($s in $presetSlugs) { $slugs.Add($s) }
}

if ($Apps) {
    foreach ($s in $Apps) { $slugs.Add($s) }
}

# De-duplicate, preserving first-seen order
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$orderedSlugs = New-Object System.Collections.Generic.List[string]
foreach ($s in $slugs) {
    if ($seen.Add($s)) { $orderedSlugs.Add($s) }
}

if ($orderedSlugs.Count -eq 0) {
    Write-Output "ERROR: No app slugs resolved. Nothing to do."
    exit 1
}

# ---------------------------------------------------------------------------
# Tool availability checks
# ---------------------------------------------------------------------------
$wingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$chocoAvailable = [bool](Get-Command choco -ErrorAction SilentlyContinue)

if (-not $wingetAvailable) {
    Write-Output "WARNING: winget was not found on PATH. Winget-based installs will fail."
}
if ($PreferChoco -and -not $chocoAvailable) {
    Write-Output "WARNING: -PreferChoco was specified but choco was not found on PATH. Falling back to winget for all apps."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-WingetInstalled {
    param([string]$WingetId)

    if (-not $wingetAvailable) { return $false }

    $idToCheck = $WingetId
    $extraArgs = @()
    if ($WingetId -like 'msstore:*') {
        $idToCheck = $WingetId.Substring('msstore:'.Length)
    }

    $null = & winget list --id $idToCheck -e --accept-source-agreements 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Install-WithWinget {
    param([string]$WingetId)

    $idToInstall = $WingetId
    $sourceArgs = @()
    if ($WingetId -like 'msstore:*') {
        $idToInstall = $WingetId.Substring('msstore:'.Length)
        $sourceArgs = @('--source', 'msstore')
    }

    $wingetArgs = @(
        'install',
        '--id', $idToInstall,
        '-e',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent'
    ) + $sourceArgs

    & winget @wingetArgs
    return $LASTEXITCODE
}

function Install-WithChoco {
    param([string]$ChocoId)

    & choco install $ChocoId -y --no-progress
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Main install loop
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

Write-Output ""
Write-Output "========================================"
Write-Output "  Install-Apps"
Write-Output "========================================"
Write-Output "Catalog : $Catalog"
if ($Preset) { Write-Output "Preset  : $Preset" }
Write-Output "Apps    : $($orderedSlugs.Count) requested"
if ($DryRun) { Write-Output "Mode    : DRY RUN (no changes will be made)" }
Write-Output ""

foreach ($slug in $orderedSlugs) {
    if (-not $catalogMap.ContainsKey($slug)) {
        Write-Output "[skip] $slug -- not found in catalog"
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $slug
            Status   = 'NotInCatalog'
            ExitCode = ''
        })
        continue
    }

    $entry = $catalogMap[$slug]
    $displayName = $entry.content
    $wingetId = $entry.winget
    $chocoId = $entry.choco

    $useChoco = $false
    if ($PreferChoco -and $chocoAvailable -and $chocoId -and $chocoId -ne 'na') {
        $useChoco = $true
    }

    Write-Output "----------------------------------------"
    Write-Output "[$slug] $displayName"

    if (-not $useChoco -and (-not $wingetId -or $wingetId -eq 'na')) {
        Write-Output "  No winget id available and choco not selected/available -- skipping."
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = 'Failed'
            ExitCode = 'no-installer'
        })
        continue
    }

    # Already-installed check (winget only; choco has no cheap equivalent
    # here, so choco-path installs just proceed -- choco install is
    # idempotent and will report "already installed").
    if (-not $useChoco -and $wingetId -and $wingetId -ne 'na') {
        $alreadyInstalled = Test-WingetInstalled -WingetId $wingetId
        if ($alreadyInstalled) {
            Write-Output "  Already installed (winget id: $wingetId) -- skipping."
            $results.Add([pscustomobject]@{
                Slug     = $slug
                Name     = $displayName
                Status   = 'Skipped'
                ExitCode = ''
            })
            continue
        }
    }

    if ($DryRun) {
        if ($useChoco) {
            Write-Output "  [dry-run] Would run: choco install $chocoId -y --no-progress"
        } else {
            $shownId = $wingetId
            $note = ''
            if ($wingetId -like 'msstore:*') {
                $shownId = $wingetId.Substring('msstore:'.Length)
                $note = ' --source msstore'
            }
            Write-Output "  [dry-run] Would run: winget install --id $shownId -e --accept-package-agreements --accept-source-agreements --silent$note"
        }
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = 'DryRun'
            ExitCode = ''
        })
        continue
    }

    $installedVia = ''
    if ($useChoco) {
        Write-Output "  Installing via choco: $chocoId"
        $exitCode = Install-WithChoco -ChocoId $chocoId
        $installedVia = 'choco'
    } else {
        Write-Output "  Installing via winget: $wingetId"
        $exitCode = Install-WithWinget -WingetId $wingetId
        $installedVia = 'winget'

        # Automatic fallback: a winget install can fail for reasons that have
        # nothing to do with the app being unavailable -- a bad/renamed
        # manifest, an "install technology is different" refusal, a publisher
        # restriction, or a transient source error. When the catalog also
        # knows a chocolatey package for this app, try that before giving up.
        # (-PreferChoco is the opposite direction: choco FIRST by choice.)
        if ($exitCode -ne 0 -and $chocoAvailable -and $chocoId -and $chocoId -ne 'na') {
            Write-Output "  winget failed (exit code $exitCode) -- retrying via choco: $chocoId"
            $exitCode = Install-WithChoco -ChocoId $chocoId
            $installedVia = 'choco (winget fallback)'
        }
    }

    if ($exitCode -eq 0) {
        Write-Output "  OK (exit code 0, via $installedVia)"
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = 'Installed'
            ExitCode = $exitCode
        })
    } else {
        Write-Output "  FAILED (exit code $exitCode)"
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = 'Failed'
            ExitCode = $exitCode
        })
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "========================================"
Write-Output "  Summary"
Write-Output "========================================"

$installed = @($results | Where-Object { $_.Status -eq 'Installed' })
$skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
$dryRunItems = @($results | Where-Object { $_.Status -eq 'DryRun' })
$failed = @($results | Where-Object { $_.Status -in @('Failed', 'NotInCatalog') })

$results | Format-Table -AutoSize -Property Slug, Name, Status, ExitCode | Out-String | Write-Output

Write-Output "Installed : $($installed.Count)"
Write-Output "Skipped   : $($skipped.Count) (already present)"
if ($DryRun) {
    Write-Output "Dry-run   : $($dryRunItems.Count) (no changes made)"
}
Write-Output "Failed    : $($failed.Count)"

if ($failed.Count -gt 0) {
    Write-Output ""
    Write-Output "Failed items:"
    foreach ($f in $failed) {
        Write-Output "  - $($f.Slug) ($($f.Name)) -- exit code: $($f.ExitCode)"
    }
    exit 1
}

exit 0
