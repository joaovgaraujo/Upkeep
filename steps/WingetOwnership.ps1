# Which apps winget owns on this PC, and what that means for Chocolatey and
# topgrade. Dot-source; nothing runs on import.
#
# Rule: winget updates every app it tracks. Chocolatey only touches packages
# winget does not track, or failed on this run. topgrade skips a step whose
# job is replacing a binary that winget installed.
#
# steps\Update-WingetApps.ps1 starts `winget list --source winget` in the
# background and writes it to winget-list.txt; Get-WingetTrackedIds parses it
# and keeps the result in winget-tracked.json for runs that did not list.

$script:WingetListPath = Join-Path $env:LOCALAPPDATA 'Upkeep\winget-list.txt'
$script:WingetTrackedPath = Join-Path $env:LOCALAPPDATA 'Upkeep\winget-tracked.json'

# Package ids from `winget list` output. Column positions come from the
# header (labels are translated, positions are not); ids are validated, so a
# truncated id ("Foo.Ba…") or a progress line is dropped, never misread.
function ConvertFrom-WingetList {
    param([string[]]$Lines)
    $ids = New-Object System.Collections.Generic.List[string]
    $header = -1
    for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
        if ("$($Lines[$i + 1])".Trim() -match '^-{5,}$') { $header = $i; break }
    }
    if ($header -lt 0) { return @() }
    # Progress output and the header share the line: keep the text after the last CR.
    $head = ("$($Lines[$header])" -split "`r")[-1]
    $cols = @([regex]::Matches($head, '\S+'))
    if ($cols.Count -lt 3) { return @() }
    $idPos = $cols[1].Index
    $verPos = $cols[2].Index
    for ($j = $header + 2; $j -lt $Lines.Count; $j++) {
        $l = "$($Lines[$j])"
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if ($l.Length -le $verPos) { continue }
        $id = $l.Substring($idPos, $verPos - $idPos).Trim()
        if ($id -match '^[A-Za-z0-9][A-Za-z0-9._+\-]*\.[A-Za-z0-9._+\-]+$') { [void]$ids.Add($id) }
    }
    @($ids | Select-Object -Unique)
}

function Get-WingetTrackedIds {
    param(
        [string]$ListPath = $script:WingetListPath,
        [string]$TrackedPath = $script:WingetTrackedPath,
        [int]$WaitSec = 60
    )
    if (Test-Path -LiteralPath $ListPath) {
        # The background listing normally finished minutes ago; wait briefly if not.
        $until = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $until -and @(Get-CimInstance Win32_Process -Filter "Name = 'winget.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -match '\slist\s+--source\s+winget' }).Count) {
            Start-Sleep -Milliseconds 500
        }
        $ids = @(ConvertFrom-WingetList -Lines @(Get-Content -LiteralPath $ListPath -Encoding UTF8 -ErrorAction SilentlyContinue))
        if ($ids.Count) {
            try { ConvertTo-Json -InputObject @($ids) | Set-Content -LiteralPath $TrackedPath -Encoding UTF8 } catch {}
            return $ids
        }
    }
    # ForEach-Object unrolls: Windows PowerShell 5.1 emits a JSON array as one object.
    @(try { Get-Content -LiteralPath $TrackedPath -Raw -ErrorAction Stop | ConvertFrom-Json | ForEach-Object { $_ } } catch { })
}

# topgrade steps that replace a binary another updater installed, with the
# winget id that owns it. Checked in topgrade 17.17's source:
#   self_update     topgrade replaces its own exe; winget then fails on it
#                   as "modified" (2026-11-23)
#   tailscale       `tailscale update`
#   wsl_update      `wsl --update`
#   antigravity_cli `agy update`
#   uv              `uv self update` (then `uv tool upgrade --all`, which the
#                   caller runs itself so uv tools still update)
# Not listed: rustup (mostly toolchains), opencode (self-upgrades only script
# installs), the editor extension steps (winget does not update extensions).
$script:TopgradeOwnedSteps = [ordered]@{
    'self_update'     = '^topgrade-rs\.topgrade$'
    'tailscale'       = '^Tailscale\.Tailscale$'
    'wsl_update'      = '^Microsoft\.WSL$'
    'antigravity_cli' = '^Google\.AntigravityCLI$'
    'uv'              = '^astral-sh\.uv$'
}

# [pscustomobject]@{ Step; Owner } for each topgrade step to skip.
function Get-TopgradeOwnedSteps {
    param([string[]]$Tracked, [string]$ChocoLib = $(if ($env:ChocolateyInstall) { Join-Path $env:ChocolateyInstall 'lib' } else { '' }))
    foreach ($step in $script:TopgradeOwnedSteps.Keys) {
        $owner = @($Tracked | Where-Object { $_ -match $script:TopgradeOwnedSteps[$step] }) | Select-Object -First 1
        if (-not $owner -and $step -eq 'self_update' -and $ChocoLib -and (Test-Path -LiteralPath (Join-Path $ChocoLib 'topgrade'))) {
            $owner = 'Chocolatey (topgrade)'
        }
        if ($owner) { [pscustomobject]@{ Step = $step; Owner = $owner } }
    }
}
