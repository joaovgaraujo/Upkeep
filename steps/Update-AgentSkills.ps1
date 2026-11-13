<#
.SYNOPSIS
    Keeps Claude Code's agent skills (~\.claude\skills) up to date from where
    each one came from.

.DESCRIPTION
    topgrade's "GitHub CLI Skills" step runs `gh skill update`, which only
    moves skills whose SKILL.md records the GitHub repo they came from.
    Skills copied in by hand have no such record, so it skipped all 13 on
    this PC with "has no GitHub metadata" (2026-11-07). This step gives each
    skill a source and updates it from there:

      * gh       - a GitHub repo laid out as skills/*/SKILL.md. A skill without
                   metadata is reinstalled once with `gh skill install`, which
                   records the repo; from then on topgrade's step updates it.
      * git      - a folder in any git repository, synced by this step. Used
                   for repos `gh skill` cannot read (blader/humanizer keeps
                   SKILL.md at its root) and for your own repos (Gitea).
      * graphify - refreshed with `graphify install --platform claude` when
                   the graphify package is newer than the skill copy.

    Sources come from skill-sources.json (shipped), then settings.json:
      "AgentSkillSources": { "<name>": { "type": "git", "url": "...", "path": "<folder>" } }
      "AgentSkillRepos":   [ "http://host/owner/claude-skills.git" ]   every top-level
                           folder with a SKILL.md is a skill, installed if missing
      "AgentSkillKeep":    [ "<name>" ]   never update these
    A private http(s) repo that is not on github.com is read with the
    GITEA_TOKEN environment variable.

    A git skill is only replaced while it still matches what this step last
    installed. One edited since is left alone and listed at the end of the
    run. The first time a skill is taken over, the old copy is backed up to
    %LOCALAPPDATA%\Upkeep\Backups\skills.

    Skills with no source are looked up on GitHub (`gh skill search`, at most
    once a week per skill) and any repo publishing a skill of the same name is
    reported, not installed: most hits are forks.

.PARAMETER Detect
    Print the managed skills, their source and whether they are kept, as
    JSON. No network, no changes.

.NOTES
    Exit codes: 0 = done; 2 = no skills folder; 3 = some need attention
    (listed at the end of the run); 1 = an update failed.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [switch]$Detect,
    [switch]$AsUser,
    [string]$SettingsPath,
    [string]$CatalogPath,
    [string]$SkillsDir,
    # The `skills` CLI's lock (npx skills, topgrade's "Skills" step).
    [string]$AgentsLockPath
)

$ErrorActionPreference = 'Continue'
# Not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot empty in a
# param default under -File (the 1.8.6 AI CLI bug).
$root = Split-Path $PSScriptRoot -Parent
if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'settings.json' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $root 'skill-sources.json' }
if (-not $SkillsDir) { $SkillsDir = Join-Path $env:USERPROFILE '.claude\skills' }
if (-not $AgentsLockPath) { $AgentsLockPath = Join-Path $env:USERPROFILE '.agents\.skill-lock.json' }
. (Join-Path $PSScriptRoot 'Deelevate.ps1')

function Write-Log {
    param([string[]]$Lines)
    $Lines | Write-Host
    if ($LogFile) { try { $Lines | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}

# Files under the skills folder the account can't read with its normal
# token. graphify's skill had a references folder like that (created
# 2026-11-07 during an elevated run), so `graphify install` failed with
# "Access is denied" on every run. Only the elevated engine can give it back.
function Repair-SkillAccess {
    if (-not (Test-Path -LiteralPath $SkillsDir)) { return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $me.User
    $broken = @()
    $denied = @()
    $items = @(Get-ChildItem -LiteralPath $SkillsDir -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable denied)
    foreach ($e in $denied) { if ($e.TargetObject) { $broken += "$($e.TargetObject)" } }
    foreach ($i in $items) {
        try {
            $acl = Get-Acl -LiteralPath $i.FullName -ErrorAction Stop
            $mine = @($acl.Access | Where-Object {
                    $_.AccessControlType -eq 'Allow' -and
                    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -and
                    $(try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid } catch { $false })
                })
            if (-not $mine.Count) { $broken += $i.FullName }
        } catch { $broken += $i.FullName }
    }
    $tops = @($broken | Sort-Object -Unique | Sort-Object Length | Where-Object { $_ })
    $done = @()
    foreach ($b in $tops) {
        if (@($done | Where-Object { $b.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        & takeown.exe /F $b /R /D Y 2>&1 | Out-Null
        & icacls.exe $b /reset /T /C /Q 2>&1 | Out-Null
        & icacls.exe $b /setowner $me.Name /T /C /Q 2>&1 | Out-Null
        $done += $b
        Write-Log "[skills] Gave your account back access to $b (an elevated process had written it)."
    }
}

# Skills live in the user profile: never write them with an admin token.
if (-not $Detect -and -not $AsUser -and (Test-Elevated)) {
    Repair-SkillAccess
    $self = $PSCommandPath.Replace("'", "''")
    $cmd = "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$self' -AsUser"
    foreach ($p in @('SettingsPath', 'CatalogPath', 'SkillsDir', 'AgentsLockPath')) {
        $v = (Get-Variable $p -ValueOnly).Replace("'", "''")
        $cmd += " -$p '$v'"
    }
    $r = Invoke-Deelevated -Command $cmd -TimeoutSec 1800
    if ($r.Reason -eq 'UserPowerShell') {
        # A network drive holds up the user's PowerShell. The elevated engine
        # is the same account and doesn't see that drive, so the skills are
        # updated from here; the files are the same ones in the same profile.
        Write-Log "[skills] $($r.Output) Updating from the engine's own process instead (same account)."
    } elseif ($null -eq $r -or $r.Status -eq 'Unavailable') {
        # Nothing was attempted (no desktop session for this account), so the
        # summary says skipped (exit 2), not error.
        Write-Log "[skills] Skipped: $("$($r.Output)".Trim()) Skills were not updated."
        exit 2
    } else {
        Write-Log ("$($r.Output)".TrimEnd() -split "`r?`n")
        exit $r.ExitCode
    }
}

# --- Sources ------------------------------------------------------------------
function Read-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $null }
}
$settings = Read-Json $SettingsPath
$sources = [ordered]@{}
$catalog = Read-Json $CatalogPath
if ($catalog) { foreach ($p in $catalog.PSObject.Properties) { if ($p.Name -notlike '_*') { $sources[$p.Name] = $p.Value } } }
# Skill name -> "owner/repo/path" of a published version to watch, not install.
$upstreams = @{}
if ($catalog -and $catalog._upstreams) {
    foreach ($p in $catalog._upstreams.PSObject.Properties) { if ($p.Name -notlike '_*') { $upstreams[$p.Name] = "$($p.Value)" } }
}
$keep = @()
$repos = @()
if ($settings) {
    if ($settings.AgentSkillSources) { foreach ($p in $settings.AgentSkillSources.PSObject.Properties) { $sources[$p.Name] = $p.Value } }
    if ($settings.AgentSkillKeep) { $keep = @($settings.AgentSkillKeep | ForEach-Object { "$_" }) }
    if ($settings.AgentSkillRepos) { $repos = @($settings.AgentSkillRepos | ForEach-Object { "$_" }) }
}

$stateDir = Join-Path $env:LOCALAPPDATA 'Upkeep'
$cacheDir = Join-Path $stateDir 'skill-repos'
$statePath = Join-Path $stateDir 'skill-sync.json'
$state = @{}
$saved = Read-Json $statePath
if ($saved) { foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = "$($p.Value)" } }

# "<repo>-<8 hex of the URL>". The whole URL as a folder name pushed git's
# pack files past the 260-character path limit ("fetch-pack: invalid
# index-pack output").
function Get-CacheDir {
    param([string]$Url)
    $name = (($Url.TrimEnd('/') -replace '\.git$', '') -split '[/\\]')[-1] -replace '[^A-Za-z0-9._-]', '_'
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))) -replace '-', '').Substring(0, 8).ToLower()
    Join-Path $cacheDir "$name-$h"
}

# git with the Gitea token for a private non-GitHub http(s) repo. The token
# goes in a header for this one command, never into the repo's config.
function Invoke-Git {
    param([string]$Url, [string[]]$GitArgs)
    $auth = @()
    if ($Url -match '^https?://' -and $Url -notmatch '://([^/]*\.)?github\.com/' -and $env:GITEA_TOKEN) {
        $auth = @('-c', "http.extraHeader=Authorization: token $($env:GITEA_TOKEN)")
    }
    $out = & git @auth @GitArgs 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Clones or fast-forwards a repo into the cache once per run.
$script:fetched = @{}
$script:fetchFailures = 0
function Sync-Repo {
    param([string]$Url)
    if ($script:fetched.ContainsKey($Url)) { return $script:fetched[$Url] }
    $dir = Get-CacheDir $Url
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        $r = Invoke-Git $Url @('-C', $dir, 'fetch', '--depth', '1', '--quiet', 'origin')
        if ($r.ExitCode -eq 0) { $r = Invoke-Git $Url @('-C', $dir, 'reset', '--hard', '--quiet', 'FETCH_HEAD') }
    } else {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        $r = Invoke-Git $Url @('clone', '--depth', '1', '--quiet', $Url, $dir)
    }
    $result = if ($r.ExitCode -eq 0) { $dir } else { $null }
    if (-not $result) {
        # Windows PowerShell 5.1 wraps git's stderr in an error record; the
        # useful line is git's own "fatal:" one, not the wrapper's last line.
        $lines = "$($r.Output)" -split "`r?`n" | Where-Object { $_ -match '\S' }
        $last = ($lines | Where-Object { $_ -match '(fatal|error):' } | Select-Object -First 1) -replace '^git(\.exe)? : ', ''
        if (-not $last) { $last = $lines | Select-Object -Last 1 }
        $script:fetchFailures++
        # Server down: fall back to the last copy fetched, so the repo's
        # skills keep their source (and are not looked up as sourceless).
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            Write-Log "[skills] Could not fetch $Url : $last - using the copy from the last run."
            $result = $dir
        } else {
            Write-Log "[skills] Could not fetch $Url : $last"
        }
    }
    $script:fetched[$Url] = $result
    $result
}

# Content hash of a skill folder: relative paths plus file contents with line
# endings normalized, so a CRLF checkout matches an LF one. Backups, VCS
# folders and graphify's version stamp are not part of a skill.
function Get-SkillHash {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return '' }
    $base = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\') + '\'
    $sha = [Security.Cryptography.SHA256]::Create()
    $sb = New-Object Text.StringBuilder
    $files = Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | Where-Object {
        $rel = $_.FullName.Substring($base.Length)
        $rel -notmatch '(^|\\)\.(git|github)(\\|$)' -and $rel -notmatch '\.bak(-[^\\]*)?$' -and $rel -ne '.graphify_version'
    } | Sort-Object { $_.FullName.Substring($base.Length).ToLowerInvariant() }
    foreach ($f in $files) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $text = [Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")
        $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', ''
        [void]$sb.Append($f.FullName.Substring($base.Length).ToLowerInvariant().Replace('\', '/')).Append(':').Append($h).Append("`n")
    }
    [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString()))) -replace '-', ''
}

function Backup-Skill {
    param([string]$Name)
    $src = Join-Path $SkillsDir $Name
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $dest = Join-Path $stateDir ("Backups\skills\{0}-{1}" -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
    $dest
}

# Replaces the skill folder with $From, leaving out VCS and CI folders.
function Install-SkillFolder {
    param([string]$Name, [string]$From)
    $dest = Join-Path $SkillsDir $Name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem -LiteralPath $From -Force | Where-Object { $_.Name -notin @('.git', '.github') } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force -ErrorAction Stop }
}

function Get-GhMetadata {
    param([string]$Name)
    $md = Join-Path (Join-Path $SkillsDir $Name) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $md)) { return $null }
    $m = Select-String -LiteralPath $md -Pattern '^\s*github-repo:\s*(\S+)' | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

function Format-Source {
    param($Src)
    switch ("$($Src.type)") {
        'gh' { "GitHub $($Src.repo)" }
        'git' { $u = "$($Src.url)" -replace '^https?://(oauth2:[^@]*@)?', '' -replace '\.git$', ''; if ("$($Src.path)" -and "$($Src.path)" -ne '.') { "$u/$($Src.path)" } else { $u } }
        'graphify' { 'graphify package' }
        default { 'unknown' }
    }
}

# --- Skills the `skills` CLI tracks -------------------------------------------
# topgrade's "Skills" step runs `skills update`, which updates every skill in
# ~\.agents\.skill-lock.json. Those skills have one owner: this step leaves
# them alone. Before, both updated the same skills: `skills update` rewrote
# SKILL.md without gh's metadata, and this step then backed the skill up and
# reinstalled it with gh on every run (officecli, 2026-11-13).
#
# `gh skill install <repo> engineering/domain-modeling` records its lock entry
# under that path, but `skills update` looks skills up by name, so it failed
# with "No matching skills found" for 6 of them and topgrade's run went red.
# Such entries are renamed to the skill's name.
$lockOwned = @{}
$lock = Read-Json $AgentsLockPath
if ($lock -and $lock.skills) {
    $renamed = @()
    $entries = [ordered]@{}
    foreach ($p in $lock.skills.PSObject.Properties) { $entries[$p.Name] = $p.Value }
    foreach ($k in @($entries.Keys)) {
        if ($k -notmatch '/') { continue }
        $short = ($k -split '/')[-1]
        if (-not $short -or $entries.Contains($short)) { continue }
        $value = $entries[$k]
        $entries.Remove($k)
        $entries[$short] = $value
        $renamed += $short
    }
    if ($renamed.Count -and -not $Detect) {
        $lock.skills = [pscustomobject]$entries
        try {
            # No BOM: the skills CLI is Node, whose JSON.parse rejects one.
            [IO.File]::WriteAllText($AgentsLockPath, (ConvertTo-Json -InputObject $lock -Depth 10), (New-Object Text.UTF8Encoding($false)))
            Write-Log "[skills] Renamed $($renamed.Count) entr$(if ($renamed.Count -eq 1) { 'y' } else { 'ies' }) in the skills CLI's lock to the skill's name, so topgrade's Skills step can update them: $($renamed -join ', ')."
        } catch { Write-Log "[skills] Could not fix the skills CLI's lock: $($_.Exception.Message)" }
    }
    foreach ($k in $entries.Keys) { $lockOwned[$k] = "$($entries[$k].source)" }
}

# Skills in the folder, plus every skill in the user's repos (installed if missing).
$names = [ordered]@{}
if (Test-Path -LiteralPath $SkillsDir) {
    foreach ($d in Get-ChildItem -LiteralPath $SkillsDir -Directory) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md')) { $names[$d.Name] = $true }
    }
}

# --- Detect: list, change nothing ---------------------------------------------
if ($Detect) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $list = @()
    foreach ($n in $names.Keys) {
        $src = $sources[$n]
        $tracked = Get-GhMetadata $n
        $label = if ($src) { Format-Source $src } elseif ($tracked) { "GitHub $($tracked -replace '^https://github.com/', '')" } elseif ($lockOwned[$n]) { "GitHub $($lockOwned[$n])" } else { '' }
        if (-not $label) { continue }
        $list += [pscustomobject]@{ Name = $n; Source = $label; Keep = ($keep -contains $n) }
    }
    ConvertTo-Json -InputObject @($list) -Compress
    exit 0
}

if (-not (Test-Path -LiteralPath $SkillsDir) -and -not $repos.Count) {
    Write-Log '[skills] No Claude Code skills folder - nothing to update.'
    exit 2
}
New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null

# Repos listed in AgentSkillRepos: each top-level folder with a SKILL.md.
$repoFailed = 0
foreach ($url in $repos) {
    $dir = Sync-Repo $url
    if (-not $dir) { continue }
    foreach ($d in Get-ChildItem -LiteralPath $dir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') }) {
        if (-not $sources.Contains($d.Name)) { $sources[$d.Name] = [pscustomobject]@{ type = 'git'; url = $url; path = $d.Name } }
        $names[$d.Name] = $true
    }
}

$reportDir = Join-Path $stateDir 'Reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$manualPath = Join-Path $reportDir 'manual-updates-skills.json'
Remove-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue
$manual = @()
$failed = $repoFailed + $script:fetchFailures
$changed = 0
function Add-Manual {
    param([string]$Name, [string]$Reason, [string]$Fix)
    $script:manual += [pscustomobject]@{ Source = 'skills'; Id = $Name; Name = "skill $Name"; Reason = $Reason; Fix = $Fix }
    Write-Log "[skills] $($Name): needs attention ($Reason) - listed at the end of the run."
}

$noSource = @()
foreach ($n in @($names.Keys)) {
    $src = $sources[$n]
    if ($lockOwned.ContainsKey($n) -and "$($src.type)" -notin @('git', 'graphify')) {
        Write-Log "[skills] $($n): updated by topgrade's Skills step (skills CLI, $($lockOwned[$n]))."
        continue
    }
    if (-not $src) {
        if (-not (Get-GhMetadata $n)) { $noSource += $n }
        continue
    }
    if ($keep -contains $n) {
        Write-Log "[skills] $($n): kept as is (set to keep)."
        continue
    }
    $dest = Join-Path $SkillsDir $n
    switch ("$($src.type)") {
        'gh' {
            if (Get-GhMetadata $n) { continue }  # topgrade's gh skill step updates it
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Add-Manual $n 'GitHub CLI (gh) is not installed' 'Install it: winget install --id GitHub.cli -e'; continue }
            $bak = Backup-Skill $n
            $out = & gh skill install $src.repo $src.skill --agent claude-code --scope user --force 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and (Get-GhMetadata $n)) {
                Write-Log "[skills] $($n): now tracked from GitHub $($src.repo) and updated (old copy: $bak)."
                $changed++
            } else {
                $last = ("$out" -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
                Write-Log "[skills] $($n): gh skill install failed (exit $LASTEXITCODE): $last"
                $failed++
            }
        }
        'git' {
            $dir = Sync-Repo "$($src.url)"
            if (-not $dir) { $failed++; continue }
            $from = if ("$($src.path)" -and "$($src.path)" -ne '.') { Join-Path $dir $src.path } else { $dir }
            if (-not (Test-Path -LiteralPath (Join-Path $from 'SKILL.md'))) {
                Write-Log "[skills] $($n): no SKILL.md at $(Format-Source $src)."
                $failed++; continue
            }
            $remote = Get-SkillHash $from
            $local = Get-SkillHash $dest
            if ($local -eq $remote) {
                $state[$n] = $remote
                Write-Log "[skills] $($n): current ($(Format-Source $src))."
                continue
            }
            if (-not $local) {
                Install-SkillFolder $n $from
                $state[$n] = $remote
                Write-Log "[skills] $($n): installed from $(Format-Source $src)."
                $changed++
                continue
            }
            if ($state.ContainsKey($n) -and $state[$n] -ne $local) {
                Add-Manual $n "edited here since Upkeep last updated it from $(Format-Source $src)" `
                    "Push your edits to $(Format-Source $src), or delete the folder $dest to take the published version."
                continue
            }
            $bak = if (-not $state.ContainsKey($n)) { Backup-Skill $n } else { $null }
            Install-SkillFolder $n $from
            $state[$n] = $remote
            $note = if ($bak) { " (first update from there; old copy: $bak)" } else { '' }
            Write-Log "[skills] $($n): updated from $(Format-Source $src)$note."
            $changed++
        }
        'graphify' {
            if (-not (Get-Command graphify -ErrorAction SilentlyContinue)) { continue }
            $pkg = [regex]::Match("$(graphify --version 2>$null)", '\d+(\.\d+)+').Value
            $stampFile = Join-Path $dest '.graphify_version'
            $have = if (Test-Path -LiteralPath $stampFile) { (Get-Content -LiteralPath $stampFile -Raw).Trim() } else { '' }
            if ($pkg -and $have -eq $pkg) { Write-Log "[skills] $($n): current (graphify $pkg)."; continue }
            $out = & graphify install --platform claude 2>&1 | Out-String
            $now = if (Test-Path -LiteralPath $stampFile) { (Get-Content -LiteralPath $stampFile -Raw).Trim() } else { '' }
            if ($LASTEXITCODE -eq 0 -and $now -eq $pkg) {
                Write-Log "[skills] $($n): updated $have -> $pkg (graphify's own installer)."
                $changed++
            } else {
                Write-Log "[skills] $($n): graphify install --platform claude did not update it (exit $LASTEXITCODE)."
                $failed++
            }
        }
    }
}

# --- Watched upstreams: say when a published version changes ----------------
# The first look only records the newest commit; later runs list the skill
# when that folder has a newer one.
if ($upstreams.Count -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    foreach ($n in @($upstreams.Keys)) {
        if (-not $names.Contains($n) -or $keep -contains $n) { continue }
        $parts = $upstreams[$n] -split '/', 3
        if ($parts.Count -lt 3) { continue }
        $src = $sources[$n]
        if ($src -and "$($src.type)" -eq 'gh' -and "$($src.repo)" -eq "$($parts[0])/$($parts[1])") { continue }
        $json = & gh api "repos/$($parts[0])/$($parts[1])/commits?path=$($parts[2])&per_page=1" 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { continue }
        $c = @(try { $json | ConvertFrom-Json } catch { }) | Select-Object -First 1
        if (-not $c -or -not $c.sha) { continue }
        $sha = "$($c.sha)"
        $rest = "$("$($c.commit.committer.date)".Substring(0, 10)): $(("$($c.commit.message)" -split "`n")[0])"
        $key = "upstream:$n"
        if (-not $state.ContainsKey($key)) {
            $state[$key] = $sha
            Write-Log "[skills] $($n): watching github.com/$($parts[0])/$($parts[1]) for new versions (last change $rest)."
        } elseif ($state[$key] -ne $sha) {
            Add-Manual $n "github.com/$($parts[0])/$($parts[1]) published a new version ($rest)" `
                "Compare it with your copy and merge what you want: https://github.com/$($parts[0])/$($parts[1])/tree/HEAD/$($parts[2])"
            $state[$key] = $sha
        }
    }
}

# --- Skills with no source: look for a publisher, report only -----------------
# Skipped while a listed repo could not be fetched: its skills would look sourceless.
if ($noSource.Count -and $script:fetchFailures -eq 0 -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $lookPath = Join-Path $stateDir 'skill-lookups.json'
    $looked = @{}
    $seen = Read-Json $lookPath
    if ($seen) { foreach ($p in $seen.PSObject.Properties) { $looked[$p.Name] = $p.Value } }
    foreach ($n in $noSource) {
        $prev = $looked[$n]
        if ($prev -and ((Get-Date) - [datetime]$prev.When).TotalDays -lt 7) { $hits = @($prev.Hits) }
        else {
            $out = & gh skill search $n 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { break }  # rate limit: try the rest next run
            $hits = @(($out -split "`r?`n") | ForEach-Object {
                    $f = $_ -split "`t"
                    if ($f.Count -ge 2 -and $f[1].Trim() -eq $n) { $f[0].Trim() }
                } | Select-Object -First 3)
            $looked[$n] = [pscustomobject]@{ When = (Get-Date).ToString('o'); Hits = $hits }
        }
        if ($hits.Count) {
            Write-Log "[skills] $($n): no source set; GitHub has a skill of that name at $($hits -join ', '). To follow one, add it to AgentSkillSources in settings.json."
        }
    }
    try { ConvertTo-Json -InputObject ([pscustomobject]$looked) -Depth 4 | Set-Content -LiteralPath $lookPath -Encoding UTF8 } catch {}
}

try { ConvertTo-Json -InputObject ([pscustomobject]$state) | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch {}
if ($manual.Count) {
    ConvertTo-Json -InputObject @($manual) -Depth 3 | Set-Content -LiteralPath $manualPath -Encoding UTF8
}
Write-Log "[skills] Done. updated: $changed, failed: $failed, need attention: $($manual.Count)."
if ($failed) { exit 1 }
if ($manual.Count) { exit 3 }
exit 0
