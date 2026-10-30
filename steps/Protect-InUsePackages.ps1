<#
.SYNOPSIS
    Before topgrade, steers around updates that would fail only because a
    program is in use; after topgrade, undoes the temporary changes.

.DESCRIPTION
    Git for Windows: its installer refuses to run while anything from its
    folder is running (bash.exe, tail.exe, sleep.exe...). Under
    /SUPPRESSMSGBOXES its "Retry/Cancel" prompt defaults to Cancel, setup exits
    1, and topgrade's whole Chocolatey step reports a failure. Verified
    2026-10-06 in %TEMP%\chocolatey\Setup Log *.txt: "The following
    process(es) use Git for Windows: bash.exe ... Defaulting to Cancel for
    suppressed message box". Hold pins git.install (and the git meta package)
    for this run when it is outdated and in use, and records it in
    Reports\manual-updates-choco.json so it is listed at the end of the run.

    uv: topgrade's uv step ends with `uv cache prune`, which needs the cache to
    itself. Every `uv run` / `uvx` process holds it shared for as long as it
    runs, so a long-lived MCP server started through uv made the step wait 300
    s and fail on every run from 2026-10-22 to 2026-10-28 ("Cache is currently
    in-use, waiting for other uv processes to finish"). When uv processes are
    running, Hold disables topgrade's uv step for this run (via
    %LOCALAPPDATA%\SystemUpdate\topgrade-extra-args.txt, read by the engine)
    and runs `uv tool upgrade --all` itself, which does not need that lock.
    Only the cache cleanup is skipped.

    Processes are never killed: they belong to whatever the user is doing.

    Release: remove only the pins Hold added, and the extra-args file. A pin
    left behind by a run that was killed between the two is released by the
    next Hold.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Hold', 'Release')][string]$Action)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'InUse.ps1')
$heldPath = Join-Path $env:LOCALAPPDATA 'Upkeep\choco-held-pins.json'
$extraPath = Join-Path $env:LOCALAPPDATA 'SystemUpdate\topgrade-extra-args.txt'
$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
$hasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)

function Clear-HeldPins {
    if (-not $hasChoco -or -not (Test-Path -LiteralPath $heldPath)) { return }
    foreach ($name in @(Get-Content -LiteralPath $heldPath -Raw | ConvertFrom-Json)) {
        if ($name) { choco pin remove -n="$name" --limit-output 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $heldPath -Force -ErrorAction SilentlyContinue
}

function Write-Manual {
    param([string]$Source, $Entry)
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    ConvertTo-Json -Depth 3 -InputObject @($Entry) |
        Set-Content -LiteralPath (Join-Path $reportDir "manual-updates-$Source.json") -Encoding UTF8
}

Remove-Item -LiteralPath $extraPath -Force -ErrorAction SilentlyContinue
Clear-HeldPins
if ($Action -eq 'Release') { exit 0 }

# ---- uv: running uv processes block `uv cache prune` ------------------------
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvProcs = @(Get-Process -Name uv, uvx, uvw -ErrorAction SilentlyContinue)
    if ($uvProcs.Count) {
        New-Item -ItemType Directory -Path (Split-Path $extraPath) -Force | Out-Null
        Set-Content -LiteralPath $extraPath -Value '--disable uv' -Encoding ascii
        Write-Host "[uv] $(Format-ProcessCounts $uvProcs) running (uv-launched servers or tools) - they block uv's cache cleanup, so topgrade's uv step is skipped this run and uv tools are upgraded directly."
        # Bounded: if something does need the lock, fail in a minute, not five.
        $env:UV_LOCK_TIMEOUT = '60'
        $out = uv tool upgrade --all 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "[uv]   $_" }
        if ($code -ne 0) {
            $last = $out | Where-Object { $_ -match '\S' } | Select-Object -Last 1
            Write-Manual -Source 'uv' -Entry ([pscustomobject]@{
                    Source = 'uv'; Id = 'uv tool upgrade --all'; Name = 'uv tools'
                    Reason = "uv tool upgrade failed (exit $code): $last"
                    Fix = 'Close programs started through uv or uvx (MCP servers, notebooks), then run: uv tool upgrade --all'
                })
            Write-Host "[uv] uv tools need a manual update (exit $code) - listed at the end."
        }
    }
}

# ---- Git for Windows via Chocolatey ------------------------------------------
if (-not $hasChoco) { exit 0 }
Remove-Item -LiteralPath (Join-Path $reportDir 'manual-updates-choco.json') -ErrorAction SilentlyContinue

$outdated = @{}
foreach ($line in (choco outdated --limit-output 2>$null)) {
    $f = "$line" -split '\|'
    if ($f.Count -ge 3) { $outdated[$f[0].ToLower()] = [pscustomobject]@{ Current = $f[1]; Available = $f[2]; Pinned = ($f.Count -ge 4 -and $f[3] -eq 'true') } }
}
$gitPkgs = @('git.install', 'git') | Where-Object { $outdated.ContainsKey($_) -and -not $outdated[$_].Pinned }
if (-not $gitPkgs) { exit 0 }

$gitDir = Get-GitInstallDir
$users = @(Get-FolderProcesses -Folder $gitDir)
if (-not $users.Count) { exit 0 }

$list = Format-ProcessCounts $users
$held = @()
foreach ($pkg in $gitPkgs) {
    choco pin add -n="$pkg" --limit-output 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $held += $pkg }
}
if (-not $held.Count) { exit 0 }
New-Item -ItemType Directory -Path (Split-Path $heldPath) -Force | Out-Null
ConvertTo-Json -InputObject @($held) | Set-Content -LiteralPath $heldPath -Encoding UTF8

$main = if ($held -contains 'git.install') { 'git.install' } else { $held[0] }
Write-Manual -Source 'choco' -Entry ([pscustomobject]@{
        Source = 'choco'; Id = $main; Name = 'Git for Windows'
        Current = $outdated[$main].Current; Available = $outdated[$main].Available
        Reason = "Git is in use by $list"
        Fix = "Close Git Bash, terminals and tools running from $gitDir (Claude Code sessions start bash.exe), then run: choco upgrade $main -y"
    })
Write-Host "[choco] Git for Windows $($outdated[$main].Current) -> $($outdated[$main].Available) is in use by $list - holding it back this run; listed at the end."
exit 0
