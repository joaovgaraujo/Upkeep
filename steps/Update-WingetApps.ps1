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

    Three refusals are recovered automatically before giving up on a package:

      * USER SCOPE vs ADMIN (0x8A15007D / -1978335107): "The package installed
        for user scope cannot be uninstalled when running with administrator
        privileges." The engine runs elevated so it can install machine-scope
        packages, which is exactly what makes winget refuse the user-scope
        ones. Retried unelevated via steps\Deelevate.ps1. Verified against
        Ventoy 1.1.16 -> 1.1.17, which fails elevated and succeeds unelevated.

      * MODIFIED PORTABLE (-1978335145): "Unable to remove Portable package as
        it has been modified; to override this check use --force." Portable
        packages are a bare exe plus a shim, and anything that rewrites either
        (topgrade updating itself, an antivirus rewriting the file) trips the
        hash check forever after. Retried with --force. Verified against
        topgrade 17.7.0 -> 17.9.0.

      * SCOPE MISMATCH: the manifest ships only a machine-scope installer but
        the app is installed user-scope (or vice versa). winget reports this as
        the generic UPDATE_NOT_APPLICABLE, so this step checks the ARP hive the
        app is registered in and says which way round it is, because the fix
        differs (reinstall at the other scope vs let the app self-update).
        Zed is the live example: installed under HKCU in %LOCALAPPDATA%, while
        ZedIndustries.Zed's manifest declares Scope: machine.

    When a package winget can't move is also available in Chocolatey, this
    retries it there (-NoChocoFallback to disable). That genuinely recovers
    some of them: the choco package sometimes ships an installer that applies
    where winget's does not.

.PARAMETER LogFile
    Append winget's raw output here (the engine passes its run log).

.PARAMETER NoChocoFallback
    Don't retry still-pending packages through Chocolatey.

.PARAMETER NoDeelevatedRetry
    Don't retry user-scope packages unelevated. Escape hatch for environments
    where registering a scheduled task is blocked by policy.

.NOTES
    Exit codes: 0 = pending packages were updated; 2 = winget is absent;
    1 = inventory/upgrade failed or packages remain pending after retries.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [switch]$NoChocoFallback,
    [switch]$NoDeelevatedRetry,
    [switch]$RetryFailed,
    [switch]$InventoryOnly
)

$ErrorActionPreference = 'Continue'
if ($env:DASHBOARD_SKIP_OTHER_APPS -eq '1') { $NoChocoFallback = $true }
$ignorePath = Join-Path $env:LOCALAPPDATA 'Upkeep\winget-ignore.json'
$ignoredIds = @()
if (Test-Path -LiteralPath $ignorePath) { $ignoredIds = @((Get-Content -LiteralPath $ignorePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)) }
$selectedIds = @()
$selectionMode = -not [string]::IsNullOrWhiteSpace($env:UPKEEP_SELECTED_IDS)
if ($selectionMode) {
    $selectedIds = @(($env:UPKEEP_SELECTED_IDS | ConvertFrom-Json -ErrorAction Stop))
    foreach ($id in $selectedIds) { if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]+$') { throw 'Invalid selected package ID.' } }
}

. (Join-Path $PSScriptRoot 'Deelevate.ps1')

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
    $raw = winget upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($LASTEXITCODE -notin @(0, -1978335212, -1978335189)) {
        throw "winget inventory failed (exit $LASTEXITCODE): $raw"
    }
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
    for ($i = 0; $i -lt ($limit - 1); $i++) {
        if ($lines[$i + 1].Trim() -match '^-{5,}$') { $headerIdx = $i; break }
    }
    if ($headerIdx -lt 0) { return $result }
    # Column positions are stable across translated header labels.
    $columns = @([regex]::Matches($lines[$headerIdx], '\S.*?(?=\s{2,}|$)'))
    # winget pads a column with a single space when its widest value is exactly
    # as long as the label ("Version Available Source" over "Unknown 6.0.0"),
    # which merges labels above. The labels themselves are one word each, so
    # fall back to plain word boundaries before giving up.
    if ($columns.Count -lt 4) { $columns = @([regex]::Matches($lines[$headerIdx], '\S+')) }
    if ($columns.Count -lt 4) { throw 'Unrecognized winget inventory columns; refusing to report a successful inventory.' }
    $idPos = $columns[1].Index
    $verPos = $columns[2].Index
    $availPos = $columns[3].Index
    $srcPos = if ($columns.Count -gt 4) { $columns[4].Index } else { -1 }

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
        if ($id -match '^[A-Za-z0-9][A-Za-z0-9._+\-]+$' -and $avail -notmatch '\s') { $result[$id] = [pscustomobject]@{ Id = $id; Name = $l.Substring(0, $idPos).Trim(); Current = $cur; Available = $avail } }
    }
    # Never individually retry the installer that caused an unsolicited reboot.
    $result.Remove('ElectronicArts.EADesktop')
    foreach ($key in @($result.Keys)) {
        if ($ignoredIds -contains $key -or ($selectionMode -and $selectedIds -notcontains $key)) { $result.Remove($key); continue }
        $installed = Get-NameVersion -Name $result[$key].Name
        $offered = ConvertTo-LooseVersion $result[$key].Available
        if ($result[$key].Current -eq 'Unknown' -and $installed -and $offered -and $installed -ge $offered) {
            if (-not $script:versionGuarded.ContainsKey($key)) {
                $script:versionGuarded[$key] = "$installed"
                if (-not $InventoryOnly) {
                    Write-Host "[winget] $key : skipped - winget cannot read its version, but '$($result[$key].Name)' is already at or above $($result[$key].Available). Upgrading would reinstall or downgrade it."
                }
            }
            $result.Remove($key)
        }
    }
    $result
}

# First 2-4 dotted numeric parts as a [version], or $null ("156.0-1" -> 156.0).
function ConvertTo-LooseVersion {
    param([string]$Text)
    $m = [regex]::Match("$Text", '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    try { [version]$m.Value } catch { $null }
}

# Some installers never write DisplayVersion, so winget lists the package as
# "Unknown" and --include-unknown reinstalls whatever the manifest offers on
# every run - even an OLDER build (DiskGenius V6.2.0 was replaced by 6.0.0).
# Their display name often carries the real version; use it as a guard.
function Get-NameVersion {
    param([string]$Name)
    $m = [regex]::Match("$Name", '(?i)(?:^|\s)v?(\d+(\.\d+){1,3})\b')
    if (-not $m.Success) { return $null }
    ConvertTo-LooseVersion $m.Groups[1].Value
}
$script:versionGuarded = @{}

if ($InventoryOnly) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    try { ConvertTo-Json -InputObject @((Get-PendingUpgrades).Values | Sort-Object Name) -Compress }
    catch { Write-Output $_.Exception.Message; exit 1 }
    exit 0
}

# Which ARP hive is this app registered in? HKCU means a user-scope install,
# and a manifest that only ships a machine-scope installer will never apply to
# it. Matched on the winget id's product half because ARP DisplayNames rarely
# match the id ("ZedIndustries.Zed" -> "Zed").
function Get-InstallScope {
    param([string]$Id)

    $product = ($Id -split '\.')[-1]
    if (-not $product) { return 'unknown' }
    $pattern = [regex]::Escape($product)

    $hives = @(
        @{ Scope = 'user'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' },
        @{ Scope = 'machine'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' },
        @{ Scope = 'machine'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    )
    foreach ($h in $hives) {
        $hit = Get-ItemProperty $h.Path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $pattern } |
            Select-Object -First 1
        if ($hit) { return $h.Scope }
    }
    'unknown'
}

# One `winget upgrade` attempt. Returns exit code + combined output.
function Invoke-WingetUpgrade {
    param([string]$Id, [string[]]$Extra = @())

    $out = winget upgrade --id $Id --exact --include-unknown --silent --disable-interactivity `
        --accept-source-agreements --accept-package-agreements @Extra 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$retryPath = Join-Path $reportDir 'winget-failed.json'
$retryIds = @()
if ($RetryFailed) {
    if (-not (Test-Path -LiteralPath $retryPath)) { Write-Host 'No previous failed-app report.'; exit 2 }
    $retryIds = @((Get-Content -LiteralPath $retryPath -Raw | ConvertFrom-Json))
    if (-not $retryIds.Count) { Write-Host 'No failed apps to retry.'; exit 0 }
}
Write-Host '[winget] Checking for pending upgrades...'
$before = Get-PendingUpgrades
if ($RetryFailed) {
    foreach ($key in @($before.Keys)) { if ($retryIds -notcontains $key) { $before.Remove($key) } }
}
ConvertTo-Json -InputObject @($before.Keys) | Set-Content -LiteralPath $retryPath -Encoding UTF8
Write-Host "[winget] $($before.Count) package(s) have upgrades available."

Write-Host '[winget] Upgrading winget packages silently...'
$upgradeExit = 0
# `--all` would still reinstall anything the inventory filtered out, so any
# exclusion switches to per-package upgrades of exactly what is listed.
if ($RetryFailed -or $selectionMode -or $ignoredIds.Count -gt 0 -or $script:versionGuarded.Count -gt 0) {
    $output = @()
    foreach ($id in @($before.Keys)) {
        if ($id -eq 'ElectronicArts.EADesktop') { continue }
        $attempt = Invoke-WingetUpgrade -Id $id
        $output += $attempt.Output
        if ($attempt.ExitCode -ne 0) { $upgradeExit = $attempt.ExitCode }
    }
} else {
    $output = winget upgrade --all --include-unknown --silent --disable-interactivity `
        --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object ToString
    $upgradeExit = $LASTEXITCODE
}
$output | Write-Host
if ($LogFile) {
    try { $output | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {}
}

$after = Get-PendingUpgrades
$upgraded = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
$stuck = @($before.Keys | Where-Object { $after.ContainsKey($_) })
ConvertTo-Json -InputObject $stuck | Set-Content -LiteralPath $retryPath -Encoding UTF8

if ($upgraded.Count -gt 0) {
    Write-Host "[winget] Upgraded $($upgraded.Count) package(s): $($upgraded -join ', ')"
}

if ($stuck.Count -eq 0) {
    if ($upgradeExit -notin @(0, -1978335189)) {
        Write-Host "[error] winget upgrade returned $upgradeExit; see the installer output."
        exit 1
    }
    Write-Host "[result] WinGet: $($upgraded.Count) updated; 0 pending."
    Write-Host '[winget] All pending winget upgrades applied.'
    exit 0
}

# Ask winget package-by-package so we can print the REASON, not just the name.
Write-Host "[winget] $($stuck.Count) package(s) did not upgrade:"
$notApplicable = @()
foreach ($id in $stuck) {
    $attempt = Invoke-WingetUpgrade -Id $id
    $res = $attempt.Output
    $code = $attempt.ExitCode

    # -1978335107 (0x8A15007D): winget refuses to touch a user-scope package
    # while elevated. Our elevation is the whole problem, so drop it and retry.
    if (Test-RequiresNormalUser -ExitCode $code -Output $res) {
        if ($NoDeelevatedRetry) {
            Write-Host "[winget]   $id : user-scope package and we are elevated; unelevated retry disabled."
        } elseif (-not (Test-Elevated)) {
            # Already unelevated and still refused: retrying changes nothing.
            Write-Host "[winget]   $id : winget reports a user-scope conflict, but this run is not elevated."
        } else {
            Write-Host "[winget]   $id : installer requires your normal Windows user; retrying without administrator rights..."
            $deelev = Invoke-Deelevated -Command "winget upgrade --id $id --exact --include-unknown --silent --disable-interactivity --accept-source-agreements --accept-package-agreements"
            if ($null -eq $deelev) {
                Write-Host "[winget]   $id : normal-user worker unavailable. Update this app from a non-administrator terminal. Other updates continue."
            } else {
                $res = $deelev.Output
                $code = $deelev.ExitCode
                if ($code -eq 0) {
                    Write-Host "[winget]   $id : upgraded unelevated."
                    continue
                }
                Write-Host "[winget]   $id : $($deelev.Status) - $res"
            }
        }
        # Do not force an installer that explicitly rejects elevation, or start
        # a fallback while an unelevated installer might still be running.
        continue
    }

    # -1978335145: a portable package's exe or shim no longer matches what
    # winget recorded, so it won't replace it without being told to. Nothing
    # about that is recoverable by waiting -- it stays modified forever.
    if ($code -eq -1978335145 -or $res -match 'has been modified; to override this check use --force') {
        Write-Host "[winget]   $id : portable package was modified since install - retrying with --force..."
        $forced = Invoke-WingetUpgrade -Id $id -Extra @('--force')
        $res = $forced.Output
        $code = $forced.ExitCode
        if ($code -eq 0) {
            Write-Host "[winget]   $id : upgraded with --force."
            continue
        }
    }

    # 0x8A15002B = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (-1978335189)
    if ($code -eq -1978335189 -or $res -match 'No applicable upgrade found') {
        $scope = Get-InstallScope -Id $id
        $move = "$($before[$id].Current) -> $($before[$id].Available)"
        if ($scope -eq 'user') {
            Write-Host "[winget]   $id ($move): installed per-user, but the manifest's installer does not apply to that. Let the app update itself, or reinstall it machine-wide with: winget install --id $id -e --scope machine"
        } elseif ($scope -eq 'machine') {
            Write-Host "[winget]   $id ($move): installed machine-wide, but the manifest's installer does not apply to that. Let the app update itself, or reinstall it with: winget install --id $id -e --scope user"
        } else {
            Write-Host "[winget]   $id ($move): no applicable installer for how this app is installed here (the app probably self-updates, so winget's tracked version never moves)."
        }
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
    # NOT --local-only: Chocolatey 2.x REMOVED that argument ("Invalid argument
    # --local-only. This argument has been removed from the list command and
    # cannot be used", verified on 2.7.3, exit 1). It only appeared to work
    # because --limit-output skips argument validation, so the command still
    # produced rows -- meaning one choco patch away from this silently
    # returning nothing and every package reporting "not managed by chocolatey
    # either". Listing local packages is `choco list` outright in 2.x.
    foreach ($line in (choco list --limit-output 2>&1)) {
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

$remaining = Get-PendingUpgrades
foreach ($key in @($remaining.Keys)) { if (-not $before.ContainsKey($key)) { $remaining.Remove($key) } }
if ($RetryFailed) { foreach ($key in @($remaining.Keys)) { if ($retryIds -notcontains $key) { $remaining.Remove($key) } } }
ConvertTo-Json -InputObject @($remaining.Keys) | Set-Content -LiteralPath $retryPath -Encoding UTF8
if ($remaining.Count -gt 0) {
    Write-Host "[result] WinGet: $($before.Count - $remaining.Count) updated; $($remaining.Count) still pending. Successful updates were kept."
    Write-Host "[error] winget still has $($remaining.Count) pending package(s): $($remaining.Keys -join ', ')"
    exit 1
}
Write-Host '[winget] All pending packages recovered on retry.'
Write-Host "[result] WinGet: $($before.Count) updated; 0 pending after retries."
exit 0
