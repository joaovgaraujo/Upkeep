<#
.SYNOPSIS
    Holds back Chocolatey upgrades whose installer would abort because the
    program is in use, and releases the hold after topgrade.

.DESCRIPTION
    Git for Windows' installer refuses to run while anything from its folder
    is running (bash.exe, tail.exe, sleep.exe...). Under /SUPPRESSMSGBOXES its
    "Retry/Cancel" prompt defaults to Cancel, setup exits 1, and topgrade's
    whole Chocolatey step reports a failure. Verified 2026-10-06 in
    %TEMP%\chocolatey\Setup Log *.txt: "The following process(es) use Git for
    Windows: bash.exe ... Defaulting to Cancel for suppressed message box".

    Hold: if git.install (or the git meta package) is outdated and Git is in
    use, pin it for this run, name the processes, and record it in
    Reports\manual-updates-choco.json so it is listed at the end of the run.
    Processes are never killed: they belong to whatever the user is doing.

    Release: remove only the pins Hold added. A pin left behind by a run that
    was killed between the two is released by the next Hold.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Hold', 'Release')][string]$Action)

$ErrorActionPreference = 'Continue'
$heldPath = Join-Path $env:LOCALAPPDATA 'Upkeep\choco-held-pins.json'
$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
$manualPath = Join-Path $reportDir 'manual-updates-choco.json'

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { exit 0 }

function Clear-HeldPins {
    if (-not (Test-Path -LiteralPath $heldPath)) { return }
    foreach ($name in @(Get-Content -LiteralPath $heldPath -Raw | ConvertFrom-Json)) {
        if ($name) { choco pin remove -n="$name" --limit-output 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $heldPath -Force -ErrorAction SilentlyContinue
}

if ($Action -eq 'Release') { Clear-HeldPins; exit 0 }

Clear-HeldPins
Remove-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue

$outdated = @{}
foreach ($line in (choco outdated --limit-output 2>$null)) {
    $f = "$line" -split '\|'
    if ($f.Count -ge 3) { $outdated[$f[0].ToLower()] = [pscustomobject]@{ Current = $f[1]; Available = $f[2]; Pinned = ($f.Count -ge 4 -and $f[3] -eq 'true') } }
}
$gitPkgs = @('git.install', 'git') | Where-Object { $outdated.ContainsKey($_) -and -not $outdated[$_].Pinned }
if (-not $gitPkgs) { exit 0 }

$gitDir = (Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction SilentlyContinue).InstallPath
if (-not $gitDir) { $gitDir = Join-Path $env:ProgramFiles 'Git' }
$prefix = $gitDir.TrimEnd('\') + '\'
$users = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
if (-not $users.Count) { exit 0 }

$list = ($users | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }) -join ', '
$held = @()
foreach ($pkg in $gitPkgs) {
    choco pin add -n="$pkg" --limit-output 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $held += $pkg }
}
if (-not $held.Count) { exit 0 }
New-Item -ItemType Directory -Path (Split-Path $heldPath) -Force | Out-Null
ConvertTo-Json -InputObject @($held) | Set-Content -LiteralPath $heldPath -Encoding UTF8

$main = if ($held -contains 'git.install') { 'git.install' } else { $held[0] }
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
ConvertTo-Json -Depth 3 -InputObject @([pscustomobject]@{
        Source = 'choco'; Id = $main; Name = 'Git for Windows'
        Current = $outdated[$main].Current; Available = $outdated[$main].Available
        Reason = "Git is in use by $list"
        Fix = "Close Git Bash and anything running from $gitDir, then run: choco upgrade $main -y"
    }) | Set-Content -LiteralPath $manualPath -Encoding UTF8
Write-Host "[choco] Git for Windows $($outdated[$main].Current) -> $($outdated[$main].Available) is in use by $list - holding it back this run; listed at the end."
exit 0
