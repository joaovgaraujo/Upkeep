<#
.SYNOPSIS
    Updates Claude Code and the Codex CLI however each one was installed, and
    moves either one to another install method when the user chose one.

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

    The channels do not get new versions at the same time. On 2026-11-03
    winget offered Claude Code 2.1.302 while npm had 2.1.317. settings.json
    can name a preferred method per tool under "AiCliChannels" (the dashboard
    sets it from the Confirm updates screen):

        "AiCliChannels": { "claude-code": "npm", "codex": "" }

    When the preferred method is not installed yet, it is installed first and
    checked; only then are the tool's other installs removed, so a failed
    switch never leaves the tool missing. An empty value keeps the current
    method.

    Every command runs as the normal desktop user (these all live in the user
    profile; doing it elevated would leave admin-owned files there). What
    can't be done is written to Reports\manual-updates-cli.json and listed at
    the end of the run.

    `codex update` runs Windows PowerShell 5.1. Started from a PowerShell 7
    session it inherits PS7's PSModulePath and fails with "Get-FileHash is not
    recognized", so the module path is reset to the machine default first.

.PARAMETER Detect
    Print, as JSON, each installed tool with its install methods, the newest
    version each method offers, and the saved preference. Changes nothing.

.NOTES
    Exit codes: 0 = all found installs are current; 2 = none installed;
    3 = some need a manual update (listed at the end of the run);
    4 = skipped (only switches run in this mode, and none was needed).
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [switch]$Detect,
    # Defaults to settings.json next to the steps folder (set below:
    # Windows PowerShell 5.1 leaves $PSScriptRoot empty in a param default
    # when the script is started with -File, which is how the engine runs it).
    [string]$SettingsPath
)
if (-not $SettingsPath) { $SettingsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'settings.json' }

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Deelevate.ps1')

function Write-Log {
    param([string[]]$Lines)
    $Lines | Write-Host
    if ($LogFile) { try { $Lines | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}

$hasNpm = [bool](Get-Command npm -ErrorAction SilentlyContinue)
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$npmRoot = $null
if ($hasNpm) {
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
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $m = [regex]::Match("$(& $Path --version 2>$null)", '\d+(\.\d+)+')
    if ($m.Success) { $m.Value } else { 'unknown' }
}

function Get-NpmLatest {
    param([string]$Package)
    if (-not $hasNpm) { return '' }
    "$(npm view $Package version 2>$null)".Trim()
}

# The installed version of a winget package, or $null when winget does not
# list it. Matched on the id column, which is not translated.
function Get-WingetVersion {
    param([string]$Id)
    if (-not $hasWinget -or -not $Id) { return $null }
    $out = winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $m = [regex]::Match($out, [regex]::Escape($Id) + '\s+(\S+)')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

# The version winget offers. `winget show` labels are translated, so this
# takes the first "label: 1.2.3" line instead of looking for "Version:".
function Get-WingetLatest {
    param([string]$Id)
    if (-not $hasWinget -or -not $Id) { return '' }
    $out = winget show --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $m = [regex]::Match($out, '(?m)^\s*[^:\r\n]+:\s*v?(\d+(\.\d+)+)\s*$')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function Format-Method {
    param([string]$Method)
    switch ($Method) { 'native' { 'own installer' } default { $Method } }
}

$home_ = $env:USERPROFILE
$tools = @(
    @{ Key = 'claude-code'; Name = 'Claude Code'; Npm = '@anthropic-ai/claude-code'; Process = 'claude'; WingetId = 'Anthropic.ClaudeCode'
        Exe = (Join-Path $home_ '.local\bin\claude.exe')
        # Anthropic's documented Windows install command.
        NativeInstall = 'irm https://claude.ai/install.ps1 | iex'
        NativeFiles = @((Join-Path $home_ '.local\bin\claude.exe'), (Join-Path $home_ '.local\share\claude')) },
    @{ Key = 'codex'; Name = 'Codex CLI'; Npm = '@openai/codex'; Process = 'codex'; WingetId = 'OpenAI.Codex'
        Exe = (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe')
        NativeInstall = $null
        NativeFiles = @((Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex')) }
)

# Saved preference per tool: '', 'npm', 'native' or 'winget'.
$prefs = @{}
if ($SettingsPath -and (Test-Path -LiteralPath $SettingsPath)) {
    try {
        $saved = (Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json).AiCliChannels
        if ($saved) { foreach ($p in $saved.PSObject.Properties) { $prefs[$p.Name] = "$($p.Value)".Trim().ToLower() } }
    } catch {}
}

function Get-MethodVersion {
    param($Tool, [string]$Method)
    switch ($Method) {
        'npm' { Get-NpmVersion -Package $Tool.Npm }
        'native' { Get-ExeVersion $Tool.Exe }
        'winget' { Get-WingetVersion -Id $Tool.WingetId }
    }
}

function Get-InstallCommand {
    param($Tool, [string]$Method)
    switch ($Method) {
        'npm' { if ($hasNpm) { "npm install -g $($Tool.Npm)@latest" } }
        'native' { $Tool.NativeInstall }
        'winget' { if ($hasWinget) { "winget install --id $($Tool.WingetId) --exact --silent --disable-interactivity --accept-source-agreements --accept-package-agreements" } }
    }
}

function Get-RemoveCommand {
    param($Tool, [string]$Method)
    switch ($Method) {
        'npm' { "npm uninstall -g $($Tool.Npm)" }
        'native' {
            $paths = ($Tool.NativeFiles | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
            "Remove-Item -LiteralPath $paths -Recurse -Force -ErrorAction Stop"
        }
        'winget' { "winget uninstall --id $($Tool.WingetId) --exact --silent --disable-interactivity --accept-source-agreements" }
    }
}

$reset = "`$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine'); "
function Invoke-AsUser {
    param([string]$Command)
    if (Test-Elevated) {
        $r = Invoke-Deelevated -Command ($reset + $Command)
        if ($null -eq $r) { $r = [pscustomobject]@{ ExitCode = 1; Output = 'normal-user worker unavailable' } }
    } else {
        $out = Invoke-Expression ($reset + $Command + ' 2>&1') | Out-String
        $r = [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    if ($LogFile -and $r.Output) { try { $r.Output | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
    $r
}

# --- Detect: report, change nothing ----------------------------------------
if ($Detect) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $report = @()
    foreach ($t in $tools) {
        $installs = @()
        foreach ($m in @('npm', 'native', 'winget')) {
            $v = Get-MethodVersion -Tool $t -Method $m
            if ($v) { $installs += [pscustomobject]@{ Method = $m; Version = "$v" } }
        }
        if (-not $installs.Count) { continue }
        $npmLatest = Get-NpmLatest -Package $t.Npm
        $latest = [ordered]@{}
        if ($npmLatest) { $latest['npm'] = $npmLatest }
        # The native installer ships the same releases as npm.
        if ($t.NativeInstall -and $npmLatest) { $latest['native'] = $npmLatest }
        $wl = Get-WingetLatest -Id $t.WingetId
        if ($wl) { $latest['winget'] = $wl }
        $targets = @(@('npm', 'native', 'winget') | Where-Object { Get-InstallCommand -Tool $t -Method $_ })
        $report += [pscustomobject]@{ Key = $t.Key; Name = $t.Name; WingetId = $t.WingetId
            Installs = $installs; Latest = [pscustomobject]$latest; Targets = $targets
            Preferred = "$($prefs[$t.Key])" }
    }
    ConvertTo-Json -InputObject @($report) -Depth 4 -Compress
    exit 0
}

$reportDir = Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$manualPath = Join-Path $reportDir 'manual-updates-cli.json'
Remove-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue
$manual = @()
function Add-Manual {
    param($Tool, [string]$Method, [string]$Current, [string]$Reason, [string]$Fix)
    $script:manual += [pscustomobject]@{
        Source = 'ai-cli'; Id = "$($Tool.Name) ($(Format-Method $Method))"; Name = $Tool.Name
        Current = $Current; Available = 'latest'; Reason = $Reason; Fix = $Fix
    }
    Write-Log "[ai-cli] $($Tool.Name) ($(Format-Method $Method)): needs a manual update ($Reason) - listed at the end of the run."
}

# "Developer tools and other updaters" unchecked: only do switches the user asked for.
$switchOnly = $env:DASHBOARD_SKIP_OTHER_APPS -eq '1'
$didSomething = $false
$found = $false

foreach ($t in $tools) {
    $pref = "$($prefs[$t.Key])"
    if ($pref -notin @('npm', 'native', 'winget')) { $pref = '' }

    # --- Move to the preferred method ---------------------------------------
    $skipUpdate = @()
    if ($pref) {
        $current = [ordered]@{}
        foreach ($m in @('npm', 'native', 'winget')) {
            $v = Get-MethodVersion -Tool $t -Method $m
            if ($v) { $current[$m] = "$v" }
        }
        $others = @($current.Keys | Where-Object { $_ -ne $pref })
        if ($current.Count -gt 0 -and $others.Count -gt 0) {
            $found = $true
            $didSomething = $true
            $have = $current.Contains($pref)
            if (-not $have) {
                $cmd = Get-InstallCommand -Tool $t -Method $pref
                $from = ($others | ForEach-Object { "$(Format-Method $_) $($current[$_])" }) -join ', '
                if (-not $cmd) {
                    Add-Manual -Tool $t -Method $pref -Current $from -Reason "$pref is not available on this PC" -Fix "Install $pref, or pick another method under Confirm updates."
                } else {
                    Write-Log "[ai-cli] $($t.Name): switching from $from to $(Format-Method $pref)..."
                    $r = Invoke-AsUser -Command $cmd
                    $v = Get-MethodVersion -Tool $t -Method $pref
                    if ($r.ExitCode -eq 0 -and $v) {
                        Write-Log "[ai-cli] $($t.Name): installed $v with $(Format-Method $pref)."
                        $have = $true
                        $skipUpdate += $pref
                    } else {
                        $last = ("$($r.Output)" -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
                        Add-Manual -Tool $t -Method $pref -Current $from -Reason "the switch to $(Format-Method $pref) failed (exit $($r.ExitCode)): $last; the current install was kept" -Fix "Run: $cmd"
                    }
                }
            }
            # Remove the other installs only once the preferred one is there.
            if ($have) {
                foreach ($m in $others) {
                    $rm = Get-RemoveCommand -Tool $t -Method $m
                    Write-Log "[ai-cli] $($t.Name): removing the $(Format-Method $m) install ($($current[$m]))..."
                    $r = Invoke-AsUser -Command $rm
                    if (-not (Get-MethodVersion -Tool $t -Method $m)) {
                        Write-Log "[ai-cli] $($t.Name): $(Format-Method $m) install removed."
                    } else {
                        $running = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue).Count -gt 0
                        $why = if ($running) { "$($t.Name) is running and its files are in use" } else { "removal failed (exit $($r.ExitCode))" }
                        Add-Manual -Tool $t -Method $m -Current $current[$m] -Reason "switched to $(Format-Method $pref), but the old install is still there: $why" -Fix "Close $($t.Name), then run: $rm"
                    }
                    $skipUpdate += $m
                }
            }
        }
    }
    if ($switchOnly) { continue }

    # --- Update what is installed through npm and the tool's own updater ------
    $v = Get-NpmVersion -Package $t.Npm
    if ($v -and $skipUpdate -notcontains 'npm') {
        $found = $true
        # Reinstalling the same version would rewrite files a running session
        # (this one included) has open, for nothing.
        $latest = if ($hasNpm) { Get-NpmLatest -Package $t.Npm } else { '' }
        if ($latest -and $latest -eq $v) {
            Write-Log "[ai-cli] $($t.Name) (npm): already current ($v)."
        } else {
            $didSomething = $true
            $cmd = "npm install -g $($t.Npm)@latest"
            Write-Log "[ai-cli] $($t.Name) (npm) $($v): updating..."
            $r = Invoke-AsUser -Command $cmd
            $after = Get-NpmVersion -Package $t.Npm
            if ($r.ExitCode -eq 0) {
                $what = if ($after -and $after -ne $v) { "updated $v -> $after" } else { "already current ($after)" }
                Write-Log "[ai-cli] $($t.Name) (npm): $what."
            } else {
                $last = ("$($r.Output)" -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
                # npm can't replace files a running copy holds open (EBUSY/EPERM).
                $inUse = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue).Count -gt 0
                $reason = if ($inUse) { "$($t.Name) is running and its files are in use" } else { "update failed (exit $($r.ExitCode)): $last" }
                Add-Manual -Tool $t -Method 'npm' -Current $v -Reason $reason -Fix "Close $($t.Name), then run: $cmd"
            }
        }
    }
    if ((Test-Path -LiteralPath $t.Exe) -and $skipUpdate -notcontains 'native') {
        $found = $true
        $didSomething = $true
        $before = Get-ExeVersion $t.Exe
        $cmd = "& '$($t.Exe.Replace("'", "''"))' update"
        Write-Log "[ai-cli] $($t.Name) (own installer) $($before): updating..."
        $r = Invoke-AsUser -Command $cmd
        $after = Get-ExeVersion $t.Exe
        if ($r.ExitCode -eq 0) {
            $what = if ($after -and $after -ne $before) { "updated $before -> $after" } else { "already current ($after)" }
            Write-Log "[ai-cli] $($t.Name) (own installer): $what."
        } else {
            $last = ("$($r.Output)" -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
            $inUse = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue).Count -gt 0
            $reason = if ($inUse) { "$($t.Name) is running and its files are in use" } else { "update failed (exit $($r.ExitCode)): $last" }
            Add-Manual -Tool $t -Method 'native' -Current $before -Reason $reason -Fix "Close $($t.Name), then run: $($cmd.Replace('& ', ''))"
        }
    }
}

if ($manual.Count) {
    ConvertTo-Json -InputObject @($manual) -Depth 3 | Set-Content -LiteralPath $manualPath -Encoding UTF8
    exit 3
}
if ($switchOnly -and -not $didSomething) { exit 4 }
if (-not $found) {
    Write-Log '[ai-cli] Claude Code / Codex CLI: no npm or standalone install found (winget, Chocolatey, Scoop and Store installs are updated by those steps).'
    exit 2
}
exit 0
