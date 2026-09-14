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

# On a fresh Windows install App Installer (winget) is often present but not
# yet registered for the user until the Store gets around to it. Registering
# it by family name is Microsoft's documented fix and needs no download.
if (-not $wingetAvailable -and -not $DryRun) {
    Write-Output "winget not found -- trying to register App Installer..."
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
        $wingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    } catch {
        Write-Output "  Could not register App Installer: $($_.Exception.Message)"
    }
}

# Settings shared with the dashboard (settings.json next to this script).
$appTimeoutMin = 30
$settingsPath = Join-Path $PSScriptRoot 'settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $parsed = 0
        $value = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).AppInstallTimeoutMin
        if ($value -and [int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) { $appTimeoutMin = $parsed }
    } catch {}
}

if (-not $wingetAvailable) {
    Write-Output "WARNING: winget was not found on PATH. Winget-based installs will fail."
}
if ($PreferChoco -and -not $chocoAvailable) {
    Write-Output "WARNING: -PreferChoco was specified but choco was not found on PATH. Falling back to winget for all apps."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$TimedOut = 'timeout'

# Runs an installer CLI with a time limit and returns its exit code, or
# $TimedOut after killing the whole process tree. One stuck installer (e.g.
# one enabling a Windows feature while a restart is pending) otherwise holds
# winget's machine-wide install lock and blocks every app after it.
function Invoke-Timed {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutMin, [switch]$Quiet)

    $startArgs = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; NoNewWindow = $true; PassThru = $true }
    if ($Quiet) {
        $startArgs.RedirectStandardOutput = [IO.Path]::GetTempFileName()
        $startArgs.RedirectStandardError = [IO.Path]::GetTempFileName()
    }
    $proc = Start-Process @startArgs
    # Touching Handle before exit makes ExitCode available afterwards (PS 5.1).
    $null = $proc.Handle
    try {
        if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
            & taskkill.exe /PID $proc.Id /T /F | Out-Null
            return $TimedOut
        }
        $proc.WaitForExit()
        return $proc.ExitCode
    } finally {
        if ($Quiet) {
            Remove-Item -LiteralPath $startArgs.RedirectStandardOutput, $startArgs.RedirectStandardError -ErrorAction SilentlyContinue
        }
    }
}

function Test-WingetInstalled {
    param([string]$WingetId)

    if (-not $wingetAvailable) { return $false }

    $idToCheck = $WingetId
    if ($WingetId -like 'msstore:*') {
        $idToCheck = $WingetId.Substring('msstore:'.Length)
    }

    $exitCode = Invoke-Timed -FilePath 'winget' -ArgumentList @('list', '--id', $idToCheck, '-e', '--accept-source-agreements') -TimeoutMin 3 -Quiet
    return ($exitCode -eq 0)
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

    return Invoke-Timed -FilePath 'winget' -ArgumentList $wingetArgs -TimeoutMin $appTimeoutMin
}

function Install-WithChoco {
    param([string]$ChocoId)

    return Invoke-Timed -FilePath 'choco' -ArgumentList @('install', $ChocoId, '-y', '--no-progress') -TimeoutMin $appTimeoutMin
}

# ---------------------------------------------------------------------------
# Known blockers, checked before an install starts instead of waiting out the
# timeout.
# ---------------------------------------------------------------------------
# Installers that enable Windows features (WSL / Hyper-V) through servicing.
# With a restart pending, servicing parks them until that restart, so the
# install hangs and holds winget's install lock for everything after it.
$restartSensitiveIds = @('Docker.DockerDesktop', 'Microsoft.WSL', 'Canonical.Ubuntu*', 'Debian.Debian', 'SUSE.openSUSE*', 'kalilinux.kalilinux')

# Packages whose download server is intermittently unreachable or stalls from
# some networks (SDIO from Brazilian ISPs). A quick probe skips them.
$downloadProbes = @{ 'GlennDelahoy.SnappyDriverInstallerOrigin' = 'https://www.glenn.delahoy.com/' }
$probeCache = @{}

function Test-PendingReboot {
    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

function Test-UrlReachable {
    param([string]$Url)
    if (-not $probeCache.ContainsKey($Url)) {
        try {
            Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop | Out-Null
            $probeCache[$Url] = $true
        } catch {
            # Any HTTP answer (even 403/404) means the server is reachable.
            $probeCache[$Url] = [bool]$_.Exception.Response
        }
    }
    return $probeCache[$Url]
}

$rebootPending = Test-PendingReboot

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

    $skipReason = $null
    $skipStatus = 'Deferred'
    if ($rebootPending -and $wingetId -and ($restartSensitiveIds | Where-Object { $wingetId -like $_ })) {
        $skipReason = 'Windows has a restart pending; this installer enables Windows features and would hang. Restart, then install it.'
    } elseif ($wingetId -and $downloadProbes.ContainsKey($wingetId) -and -not (Test-UrlReachable $downloadProbes[$wingetId])) {
        $skipReason = "download server $($downloadProbes[$wingetId]) is unreachable from this network."
        $skipStatus = 'Unavailable'
    }
    if ($skipReason) {
        Write-Output "  Skipping: $skipReason"
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = $skipStatus
            ExitCode = ''
        })
        continue
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
        # A timeout is not retried: the same blocker would stall choco too.
        if ($exitCode -ne 0 -and $exitCode -ne $TimedOut -and $chocoAvailable -and $chocoId -and $chocoId -ne 'na') {
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
    } elseif ($exitCode -eq $TimedOut) {
        Write-Output "  TIMED OUT after $appTimeoutMin min -- stopped it and moving on (often needs a restart first)."
        $results.Add([pscustomobject]@{
            Slug     = $slug
            Name     = $displayName
            Status   = 'Failed'
            ExitCode = "timeout ${appTimeoutMin}m"
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
$deferred = @($results | Where-Object { $_.Status -in @('Deferred', 'Unavailable') })
if ($deferred.Count -gt 0) {
    Write-Output "Not now   : $($deferred.Count) ($(($deferred | ForEach-Object { $_.Slug }) -join ', ')) -- see the messages above; not counted as failures"
}
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
