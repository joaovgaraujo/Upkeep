<#
.SYNOPSIS
    Runs the winget upgrade pass and reports, per package, what it could NOT
    upgrade and why.

.DESCRIPTION
    `winget upgrade --all` prints a wall of text and returns a single exit
    code, so a package that quietly refuses to upgrade is invisible: the old
    inline version of this step piped everything through Tee-Object and always
    reported "ok". Packages could sit un-upgraded run after run with nothing
    in the summary to say so.

    This takes a before/after snapshot around the upgrade and reports the
    difference, naming every package that is still pending and the reason
    winget gave.

    The common reason is UPDATE_NOT_APPLICABLE (0x8A15002B): "A newer package
    version is available in a configured source, but it does not apply to your
    system or requirements." That means the manifest's installer doesn't match
    how the app is installed here - usually a user-scope install (HKCU) versus
    a machine-scope manifest, or an app that self-updates so winget's tracked
    version never moves. It is NOT a broken winget.

    When a package winget can't move is also available in Chocolatey, this
    retries it there (-NoChocoFallback to disable). That genuinely recovers
    some of them: Ventoy is user-scope and winget refuses it, while the choco
    package upgrades cleanly.

.PARAMETER LogFile
    Append winget's raw output here (the engine passes its run log).

.PARAMETER NoChocoFallback
    Don't retry still-pending packages through Chocolatey.

.NOTES
    Exit codes: 0 = the pass ran (even if some packages are still pending;
    those are reported, not treated as a run failure). 2 = winget is not
    installed, so there was nothing to do. 1 = the pass genuinely failed.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [switch]$NoChocoFallback
)

$ErrorActionPreference = 'Continue'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    # Exit 2 = "nothing to do here", not a failure - the engine already
    # printed its own [warn] about winget being unavailable, and reporting
    # this as an error made the two lines contradict each other in one log.
    Write-Host '[winget] winget is not available - skipping.'
    exit 2
}

# Parses `winget upgrade` table output into id -> available-version.
# winget has no --output json for upgrade, so this uses the header column
# offsets rather than splitting on whitespace (names contain spaces).
function Get-PendingUpgrades {
    $raw = winget upgrade --include-unknown --accept-source-agreements 2>&1 | Out-String
    $lines = $raw -split "`r?`n"
    $result = @{}

    # winget prints a SECOND table with the same header for packages that
    # "require explicit targeting" (Anaconda et al). Stop looking before it:
    # when nothing ordinary is pending there is no first table at all, and a
    # naive first-match would latch onto the explicit-targeting header and
    # report those as normal pending upgrades. The engine already handles
    # that set separately at the end of the run.
    $limit = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'require explicit targeting') { $limit = $i; break }
    }

    $headerIdx = -1
    for ($i = 0; $i -lt $limit; $i++) {
        if ($lines[$i] -match '^Name\s+Id\s+Version\s+Available') { $headerIdx = $i; break }
    }
    if ($headerIdx -lt 0) { return $result }

    $header = $lines[$headerIdx]
    $idPos = $header.IndexOf('Id')
    $verPos = $header.IndexOf('Version')
    $availPos = $header.IndexOf('Available')
    $srcPos = $header.IndexOf('Source')
    if ($idPos -lt 0 -or $verPos -le $idPos -or $availPos -le $verPos) { return $result }

    for ($j = $headerIdx + 2; $j -lt $limit; $j++) {
        $l = $lines[$j]
        if ([string]::IsNullOrWhiteSpace($l)) { break }
        if ($l -match '^\d+ upgrades? available') { break }
        # The pins footer ("N package(s) have pins that prevent upgrade...")
        # is long enough to survive the length check below and would be
        # sliced into a garbage package id.
        if ($l -match 'pins that prevent upgrade') { break }
        if ($l -match '^\d+ package\(s\) (have|are)') { break }
        if ($l.Length -le $availPos) { continue }

        $id = $l.Substring($idPos, $verPos - $idPos).Trim()
        $cur = $l.Substring($verPos, $availPos - $verPos).Trim()
        $end = if ($srcPos -gt $availPos -and $l.Length -gt $srcPos) { $srcPos - $availPos } else { $l.Length - $availPos }
        $avail = $l.Substring($availPos, $end).Trim()
        if ($id) { $result[$id] = [pscustomobject]@{ Current = $cur; Available = $avail } }
    }
    $result
}

Write-Host '[winget] Checking for pending upgrades...'
$before = Get-PendingUpgrades
Write-Host "[winget] $($before.Count) package(s) have upgrades available."

Write-Host '[winget] Upgrading winget packages silently...'
$output = winget upgrade --all --include-unknown --silent --disable-interactivity `
    --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object ToString
$output | Write-Host
if ($LogFile) {
    try { $output | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {}
}

$after = Get-PendingUpgrades
$upgraded = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
$stuck = @($before.Keys | Where-Object { $after.ContainsKey($_) })

if ($upgraded.Count -gt 0) {
    Write-Host "[winget] Upgraded $($upgraded.Count) package(s): $($upgraded -join ', ')"
}

if ($stuck.Count -eq 0) {
    Write-Host '[winget] All pending winget upgrades applied.'
    exit 0
}

# Ask winget package-by-package so we can print the REASON, not just the name.
Write-Host "[winget] $($stuck.Count) package(s) did not upgrade:"
$notApplicable = @()
foreach ($id in $stuck) {
    $res = winget upgrade --id $id --exact --include-unknown --silent --disable-interactivity `
        --accept-source-agreements --accept-package-agreements 2>&1 | Out-String
    $code = $LASTEXITCODE

    # 0x8A15002B = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (-1978335189)
    if ($code -eq -1978335189 -or $res -match 'No applicable upgrade found') {
        Write-Host "[winget]   $id ($($before[$id].Current) -> $($before[$id].Available)): no applicable installer for how this app is installed here (user-scope install, or the app self-updates)."
        $notApplicable += $id
    }
    elseif ($res -match 'different install technology') {
        Write-Host "[winget]   $id : blocked - the new version uses a different install technology. Uninstall it, then reinstall."
    }
    elseif ($code -eq 0) {
        Write-Host "[winget]   $id : upgraded on the individual retry."
    }
    else {
        $short = ($res -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        Write-Host "[winget]   $id : exit $code - $short"
    }
}

# Chocolatey sometimes packages the same app with an installer that DOES
# apply. Only ever UPGRADE something choco already manages: if the app isn't
# in choco's local list, `choco upgrade` would happily INSTALL a second,
# parallel copy of it - which is how you end up with the duplicate winget/choco
# tracking this project already fights elsewhere.
if (-not $NoChocoFallback -and $notApplicable.Count -gt 0 -and (Get-Command choco -ErrorAction SilentlyContinue)) {
    $localChoco = @{}
    foreach ($line in (choco list --local-only --limit-output 2>&1)) {
        $name = ($line -split '\|')[0]
        if ($name) { $localChoco[$name.ToLower()] = $true }
    }

    foreach ($id in $notApplicable) {
        # winget ids are Publisher.Product; choco ids are usually the product
        # in lowercase.
        $guess = ($id -split '\.')[-1].ToLower()
        if (-not $localChoco.ContainsKey($guess)) {
            Write-Host "[winget]   $id : not managed by chocolatey either - upgrade it manually or reinstall it."
            continue
        }
        Write-Host "[winget]   $id : also installed via choco - upgrading '$guess' instead..."
        choco upgrade $guess -y --no-progress 2>&1 | Write-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[winget]   $id : upgraded via chocolatey."
        } else {
            Write-Host "[winget]   $id : chocolatey upgrade returned $LASTEXITCODE."
        }
    }
}

Write-Host '[winget] Packages listed above need attention - they are not transient failures.'
# Still exit 0: the pass ran. These are per-package conditions reported in the
# log, not a failure of the update run.
exit 0
