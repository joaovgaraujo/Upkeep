<#
.SYNOPSIS
    Updates Claude Code and the Codex CLI however each one was installed.

.DESCRIPTION
    Both tools ship through several channels, and most of them are updated by
    nothing else in this engine:

      * npm global (@anthropic-ai/claude-code, @openai/codex). topgrade's
        "node" step is disabled in our config, so npm globals never moved.
      * Claude Code's native installer (~\.local\bin\claude.exe) and Codex's
        standalone installer (%LOCALAPPDATA%\Programs\OpenAI\Codex\bin), which
        both update through their own `update` command.
      * winget, Chocolatey, Scoop and the Store: already covered by those
        steps, so they are only mentioned here, never updated twice.

    Every install found is updated through its own channel, as the normal
    desktop user (these all live in the user profile; doing it elevated would
    leave admin-owned files there). What can't be updated is written to
    Reports\manual-updates-cli.json and listed at the end of the run.

    `codex update` runs Windows PowerShell 5.1. Started from a PowerShell 7
    session it inherits PS7's PSModulePath and fails with "Get-FileHash is not
    recognized", so the module path is reset to the machine default first.

.NOTES
    Exit codes: 0 = all found installs are current; 2 = none installed;
    3 = some need a manual update (listed at the end of the run).
#>
[CmdletBinding()]
param([string]$LogFile)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Deelevate.ps1')

$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$manualPath = Join-Path $reportDir 'manual-updates-cli.json'
Remove-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue
$manual = @()

function Write-Log {
    param([string[]]$Lines)
    $Lines | Write-Host
    if ($LogFile) { try { $Lines | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}

$npmRoot = $null
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmRoot = (npm root -g 2>$null | Select-Object -First 1)
}
# Elevated runs can miss the user's npm prefix; it is %APPDATA%\npm by default.
if (-not $npmRoot) {
    $default = Join-Path $env:APPDATA 'npm\node_modules'
    if (Test-Path -LiteralPath $default) { $npmRoot = $default }
}

function Get-NpmVersion {
    param([string]$Package)
    if (-not $npmRoot) { return $null }
    $manifest = Join-Path $npmRoot "$Package\package.json"
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    try { (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version } catch { 'unknown' }
}

function Get-ExeVersion {
    param([string]$Path)
    $m = [regex]::Match("$(& $Path --version 2>$null)", '\d+(\.\d+)+')
    if ($m.Success) { $m.Value } else { 'unknown' }
}

$tools = @(
    @{ Name = 'Claude Code'; Npm = '@anthropic-ai/claude-code'; Exe = (Join-Path $env:USERPROFILE '.local\bin\claude.exe'); Process = 'claude' },
    @{ Name = 'Codex CLI'; Npm = '@openai/codex'; Exe = (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'); Process = 'codex' }
)

$installs = @()
foreach ($t in $tools) {
    $v = Get-NpmVersion -Package $t.Npm
    # Reinstalling the same version would rewrite files a running session
    # (this one included) has open, for nothing.
    $latest = if ($v -and (Get-Command npm -ErrorAction SilentlyContinue)) { "$(npm view $t.Npm version 2>$null)".Trim() } else { '' }
    if ($v -and $latest -and $latest -eq $v) {
        Write-Log "[ai-cli] $($t.Name) (npm): already current ($v)."
    } elseif ($v) {
        $installs += [pscustomobject]@{ Tool = $t.Name; Method = 'npm'; Before = $v; Process = $t.Process
            Command = "npm install -g $($t.Npm)@latest"; Version = [scriptblock]::Create("Get-NpmVersion -Package '$($t.Npm)'") }
    }
    if (Test-Path -LiteralPath $t.Exe) {
        $exe = $t.Exe
        $installs += [pscustomobject]@{ Tool = $t.Name; Method = 'own installer'; Before = (Get-ExeVersion $exe); Process = $t.Process
            Command = "& '$($exe.Replace("'", "''"))' update"; Version = [scriptblock]::Create("Get-ExeVersion '$($exe.Replace("'", "''"))'") }
    }
}

if (-not $installs.Count) {
    Write-Log '[ai-cli] Claude Code / Codex CLI: no npm or standalone install found (winget, Chocolatey, Scoop and Store installs are updated by those steps).'
    exit 2
}

$reset = "`$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine'); "
foreach ($i in $installs) {
    Write-Log "[ai-cli] $($i.Tool) ($($i.Method)) $($i.Before): updating..."
    if (Test-Elevated) {
        $r = Invoke-Deelevated -Command ($reset + $i.Command)
        if ($null -eq $r) { $r = [pscustomobject]@{ ExitCode = 1; Output = 'normal-user worker unavailable' } }
    } else {
        $out = Invoke-Expression ($reset + $i.Command + ' 2>&1') | Out-String
        $r = [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    if ($LogFile -and $r.Output) { try { $r.Output | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
    $after = & $i.Version

    if ($r.ExitCode -eq 0) {
        $what = if ($after -and $after -ne $i.Before) { "updated $($i.Before) -> $after" } else { "already current ($after)" }
        Write-Log "[ai-cli] $($i.Tool) ($($i.Method)): $what."
        continue
    }
    $last = ("$($r.Output)" -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    # npm can't replace files a running copy holds open (EBUSY/EPERM).
    $inUse = @(Get-Process -Name $i.Process -ErrorAction SilentlyContinue).Count -gt 0
    $reason = if ($inUse) { "$($i.Tool) is running and its files are in use" } else { "update failed (exit $($r.ExitCode)): $last" }
    $manual += [pscustomobject]@{
        Source = 'ai-cli'; Id = "$($i.Tool) ($($i.Method))"; Name = $i.Tool
        Current = $i.Before; Available = 'latest'; Reason = $reason
        Fix = "Close $($i.Tool), then run: $($i.Command.Replace('& ', ''))"
    }
    Write-Log "[ai-cli] $($i.Tool) ($($i.Method)): needs a manual update ($reason) - listed at the end of the run."
}

if ($manual.Count) {
    ConvertTo-Json -InputObject @($manual) -Depth 3 | Set-Content -LiteralPath $manualPath -Encoding UTF8
    exit 3
}
exit 0
