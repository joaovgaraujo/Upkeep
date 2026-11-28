# Helpers for Setup-NewPC.ps1. Dot-source; nothing runs on import.
# Kept apart from the main script so tests can call them directly.

# ---------------------------------------------------------------------------
# Pinned winutil
# ---------------------------------------------------------------------------
# Setup runs the copy of winutil in vendor\winutil, checked against the
# SHA-256 in vendor\winutil\pin.json. Fetching the live script at run time
# meant every winutil release could rename or retire a tweak ID, change a
# tweak's behaviour or the headless summary text this script reads, without
# anything here changing. To move to a newer winutil, run
# vendor\winutil\Update-Winutil.ps1 and then tests\Winutil.Tests.ps1.
function Get-PinnedWinutil {
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path $Root 'vendor\winutil'
    $pinPath = Join-Path $dir 'pin.json'
    $file = Join-Path $dir 'winutil.ps1'
    if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { throw "winutil pin file not found: $pinPath" }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Pinned winutil not found: $file" }
    $pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($actual -ne ([string]$pin.Sha256).ToUpperInvariant()) {
        throw "Pinned winutil $($pin.Version) does not match its SHA-256 (expected $($pin.Sha256), got $actual). Restore vendor\winutil\winutil.ps1 or run vendor\winutil\Update-Winutil.ps1."
    }
    [pscustomobject]@{ Path = $file; Version = [string]$pin.Version; Sha256 = $actual }
}

# ---------------------------------------------------------------------------
# Microsoft Store search (WPFTweaksDisableStoreSearch)
# ---------------------------------------------------------------------------
# winutil's tweak denies Everyone on LocalState\store.db. Current Store
# builds name the file store-<32 hex>.db instead, so upstream's icacls call
# hits a missing file and the tweak silently does nothing.
function Find-StoreDatabase {
    param([string]$StoreState = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState'))
    $plain = Join-Path $StoreState 'store.db'
    if (Test-Path -LiteralPath $plain -PathType Leaf) { return @($plain) }
    @(Get-ChildItem -LiteralPath $StoreState -File -Filter 'store-*.db' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^store-[0-9a-f]{32}\.db$' } |
        ForEach-Object { $_.FullName })
}

function Test-StoreSearchBlocked {
    param([Parameter(Mandatory)][string]$Path)
    $everyone = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Deny' -and $rule.IdentityReference -eq $everyone -and
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) {
            return $true
        }
    }
    return $false
}

# Returns @{ Status; Detail } for the phase report. Never throws for the
# "nothing to do" cases; throws when icacls itself fails.
function Set-StoreSearchBlocked {
    param(
        [Parameter(Mandatory)][string]$ReportDir,
        [string]$StoreState = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState')
    )
    $found = @(Find-StoreDatabase -StoreState $StoreState)
    if ($found.Count -ne 1) {
        return [pscustomobject]@{ Status = 'Skipped'; Detail = "Expected one Store database, found $($found.Count). Open Microsoft Store once, then run setup again." }
    }
    $database = $found[0]
    # A second run would otherwise back up the already-blocked ACL and
    # lose the original one.
    if (Test-StoreSearchBlocked -Path $database) {
        return [pscustomobject]@{ Status = 'OK'; Detail = 'Already applied: the Store database already denies Everyone.' }
    }
    $aclBackup = Join-Path $ReportDir 'store-search-acl.txt'
    & icacls.exe $database /save $aclBackup | Write-Output
    if ($LASTEXITCODE -ne 0) { throw "Store database ACL backup failed (icacls exit $LASTEXITCODE)." }
    & icacls.exe $database /deny '*S-1-1-0:F' | Write-Output
    if ($LASTEXITCODE -ne 0) { throw "Store search tweak failed (icacls exit $LASTEXITCODE)." }
    [pscustomobject]@{ Status = 'Completed'; Detail = "Store database permissions updated. To undo: icacls `"$(Split-Path $database)`" /restore `"$aclBackup`"" }
}

# ---------------------------------------------------------------------------
# Smart App Control
# ---------------------------------------------------------------------------
# On a clean Windows 11 install Smart App Control starts in Evaluation mode
# and can switch itself On. When On, it blocks unsigned or not-yet-reputable
# installers, drivers and DLLs (SDIO drivers, some Git for Windows DLLs, small
# vendors' setups) with "Bad Image" / 0xc0e90002 errors or no message at all.
# State lives in VerifiedAndReputablePolicyState: 0 Off, 1 On, 2 Evaluation.
$script:SacPolicyKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'

function Get-SmartAppControlState {
    param([string]$PolicyKey = $script:SacPolicyKey)
    $value = $null
    try { $value = (Get-ItemProperty -LiteralPath $PolicyKey -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { }
    switch ($value) {
        0 { return 'Off' }
        1 { return 'On' }
        2 { return 'Evaluation' }
        default { return 'Unknown' }
    }
}

# What Defender reports as in force right now (it can lag the registry
# until CI policies are refreshed or Windows restarts). $null if unknown.
function Get-SmartAppControlEnforced {
    try {
        $s = [string](Get-MpComputerStatus -ErrorAction Stop).SmartAppControlState
        if ($s) { return $s }
    } catch { }
    return $null
}

function Disable-SmartAppControl {
    param(
        [Parameter(Mandatory)][string]$ReportDir,
        [string]$PolicyKey = $script:SacPolicyKey,
        [string]$CiTool = (Join-Path $env:SystemRoot 'System32\CiTool.exe'),
        [scriptblock]$GetEnforced = { Get-SmartAppControlEnforced }
    )
    $before = Get-SmartAppControlState -PolicyKey $PolicyKey
    if ($before -eq 'Off') {
        return [pscustomobject]@{ Status = 'OK'; Detail = 'Already off.'; RestartNeeded = $false }
    }
    if ($before -eq 'Unknown') {
        return [pscustomobject]@{ Status = 'Skipped'; Detail = 'Smart App Control is not present on this Windows version.'; RestartNeeded = $false }
    }
    [pscustomobject]@{ Before = $before; Time = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDir 'smart-app-control-before.json') -Encoding UTF8
    Set-ItemProperty -LiteralPath $PolicyKey -Name 'VerifiedAndReputablePolicyState' -Value 0 -Type DWord -ErrorAction Stop
    if (Test-Path -LiteralPath $CiTool) {
        # Asks Code Integrity to reload its policies now instead of at boot.
        # "No restart needed" is decided by what Defender reports next, not
        # by this exit code.
        & $CiTool --refresh 2>&1 | Out-Null
    }
    $enforced = & $GetEnforced
    $note = 'Recent Windows 11 builds can turn it back on in Windows Security > App & browser control; older builds only after a reset or reinstall.'
    if ($enforced -eq 'Off') {
        return [pscustomobject]@{ Status = 'OK'; Detail = "Turned off (was $before). $note"; RestartNeeded = $false }
    }
    [pscustomobject]@{ Status = 'Warning'; Detail = "Set to off (was $before); Windows still reports '$enforced' until a restart, so some installs in this run may be blocked. Restart, then use Retry failed. $note"; RestartNeeded = $true }
}

# Files Smart App Control blocked since $Since, from the CodeIntegrity log
# (event 3077, policy VerifiedAndReputableDesktop). Matches on the policy
# name in the event XML, which is not translated, rather than the message.
function Get-SmartAppControlBlocks {
    param([datetime]$Since)
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3077, 3033; StartTime = $Since } -ErrorAction Stop)
    } catch { return @() }
    $files = foreach ($e in $events) {
        $xml = [xml]$e.ToXml()
        if ($xml.OuterXml -notmatch 'VerifiedAndReputable') { continue }
        $name = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'File Name' } | Select-Object -First 1
        if ($name -and $name.'#text') { Split-Path -Leaf $name.'#text' }
    }
    @($files | Select-Object -Unique)
}
