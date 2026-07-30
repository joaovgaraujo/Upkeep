<#
.SYNOPSIS
    Exports everything that runs automatically on this PC into a Markdown
    report: startup programs (with on/off state and the file they launch),
    boot/logon scheduled tasks (with the executable and arguments), and all
    Windows services (with binary path, start type, state and description).
    Made for researching items one by one.

.PARAMETER OutFile
    Output path. Default: StartupReport.md next to this script.

.PARAMETER Open
    Open the report in the default editor when done.
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'StartupReport.md' }

$sb = [System.Text.StringBuilder]::new()
function Add-Line([string]$s = '') { $null = $sb.AppendLine($s) }

Add-Line "# Startup Report - $env:COMPUTERNAME"
Add-Line ""
Add-Line "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by Upkeep. Everything that starts automatically:"
Add-Line "startup programs, boot/logon scheduled tasks, and Windows services, with the file each one launches."
Add-Line ""

# ---------------------------------------------------------------------------
# 1. Startup programs (Run/RunOnce keys + Startup folders + on/off state)
# ---------------------------------------------------------------------------
Add-Line "## Startup programs"
Add-Line ""

function Get-ApprovedState([string]$aKey, [string]$aName) {
    if (-not $aKey) { return 'n/a (one-time)' }
    try {
        $v = (Get-ItemProperty -Path $aKey -Name $aName -ErrorAction Stop).$aName
        if ($v -and ($v[0] -band 1)) { return 'DISABLED' }
    } catch {}
    return 'enabled'
}

$runPairs = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = '' },
    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = '' },
    @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)
foreach ($p in $runPairs) {
    if (Test-Path $p.Key) {
        (Get-ItemProperty $p.Key).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' } |
            ForEach-Object {
                $state = Get-ApprovedState $p.Approved $_.Name
                Add-Line "- **$($_.Name)** [$state]"
                Add-Line "  - Location: ``$($p.Key)``"
                Add-Line "  - Launches: ``$([string]$_.Value)``"
            }
    }
}
$folderPairs = @(
    @{ Dir = [Environment]::GetFolderPath('Startup');
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
    @{ Dir = [Environment]::GetFolderPath('CommonStartup');
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
)
foreach ($f in $folderPairs) {
    if ($f.Dir -and (Test-Path $f.Dir)) {
        Get-ChildItem -LiteralPath $f.Dir -File | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $state = Get-ApprovedState $f.Approved $_.Name
            $target = $_.FullName
            if ($_.Extension -eq '.lnk') {
                try {
                    $sh = New-Object -ComObject WScript.Shell
                    $lnk = $sh.CreateShortcut($_.FullName)
                    $target = ('{0} {1}' -f $lnk.TargetPath, $lnk.Arguments).Trim()
                } catch {}
            }
            Add-Line "- **$($_.Name)** [$state]"
            Add-Line "  - Location: ``$($f.Dir)`` (Startup folder)"
            Add-Line "  - Launches: ``$target``"
        }
    }
}
Add-Line ""

# ---------------------------------------------------------------------------
# 2. Scheduled tasks with boot/logon triggers
# ---------------------------------------------------------------------------
Add-Line "## Scheduled tasks (run at boot or sign-in)"
Add-Line ""
Get-ScheduledTask | ForEach-Object {
    $triggers = @($_.Triggers) | Where-Object { $_ -and ($_.PSObject.TypeNames -match 'LogonTrigger|BootTrigger') }
    if (@($triggers).Count -gt 0) {
        $actions = @($_.Actions) | ForEach-Object {
            if ($_.Execute) { ('{0} {1}' -f $_.Execute, $_.Arguments).Trim() }
        }
        Add-Line "- **$($_.TaskName)** [$($_.State)]"
        Add-Line "  - Folder: ``$($_.TaskPath)``"
        if ($_.Author) { Add-Line "  - Author: $($_.Author)" }
        foreach ($a in $actions) { Add-Line "  - Runs: ``$a``" }
        if ($_.Description) {
            Add-Line "  - Description: $((($_.Description) -replace '\s+', ' ').Trim())"
        }
    }
}
Add-Line ""

# ---------------------------------------------------------------------------
# 3. Windows services
# ---------------------------------------------------------------------------
Add-Line "## Services"
Add-Line ""
Get-CimInstance Win32_Service | Sort-Object DisplayName | ForEach-Object {
    Add-Line "- **$($_.DisplayName)** (``$($_.Name)``) [$($_.StartMode) / $($_.State)]"
    if ($_.PathName)    { Add-Line "  - File: ``$($_.PathName)``" }
    if ($_.StartName)   { Add-Line "  - Runs as: $($_.StartName)" }
    if ($_.Description) { Add-Line "  - Description: $((($_.Description) -replace '\s+', ' ').Trim())" }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Output "Report written: $OutFile"
if ($Open) { Invoke-Item $OutFile }
