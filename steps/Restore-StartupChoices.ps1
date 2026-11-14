<#
.SYNOPSIS
    Puts back the startup choices made on Upkeep's Startup & Services page
    after app updates have undone them.

.DESCRIPTION
    App installers turn their own startup items back on. On 2026-11-13 a
    winget update of Tailscale set its service back to Automatic and
    re-created its Startup-folder shortcut, and the RustDesk installer added
    one of its own. The page records every item turned off there in
    %LOCALAPPDATA%\Upkeep\startup-choices.json (gui\src\choices.rs):

      startup   a Run-key or Startup-folder item, by its StartupApproved value
      tasks     a scheduled task, kept disabled
      services  a service kept at Manual or Disabled

    This step runs after the updates and switches off again whatever an
    update switched back on. An item that no longer exists is skipped and
    kept in the file, in case the app comes back.

.NOTES
    Exit codes: 0 = done (nothing to do, or put back); 2 = no choices recorded;
    1 = something could not be put back.
#>
[CmdletBinding()]
param(
    [string]$ChoicesPath = (Join-Path $env:LOCALAPPDATA 'Upkeep\startup-choices.json'),
    [string]$LogFile
)
$ErrorActionPreference = 'Continue'

function Write-Log([string]$Line) {
    Write-Host $Line
    if ($LogFile) { try { $Line | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}

if (-not (Test-Path -LiteralPath $ChoicesPath)) { exit 2 }
try { $choices = Get-Content -LiteralPath $ChoicesPath -Raw | ConvertFrom-Json } catch {
    Write-Log "[startup] Could not read $ChoicesPath : $($_.Exception.Message)"
    exit 1
}
$total = @($choices.startup).Count + @($choices.tasks).Count + @($choices.services).Count
if (-not $total) { exit 2 }

$putBack = 0
$failed = 0

# --- Startup items -------------------------------------------------------------
# StartupApproved: first byte even = on, odd = off (what Task Manager writes).
# The item itself lives in the Run key next to the approved key's name, or
# as a file in the matching Startup folder.
function Test-StartupItemExists($c) {
    $key = "$($c.approved_key)"
    $name = "$($c.approved_name)"
    if ($key -match '\\StartupApproved\\StartupFolder$') {
        $folder = if ($key -like 'HKLM:*') { [Environment]::GetFolderPath('CommonStartup') } else { [Environment]::GetFolderPath('Startup') }
        return (Test-Path -LiteralPath (Join-Path $folder $name))
    }
    $run = switch -regex ($key) {
        '^HKCU:.*\\StartupApproved\\Run$' { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
        '^HKLM:.*\\StartupApproved\\Run$' { 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' }
        '^HKLM:.*\\StartupApproved\\Run32$' { 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
        default { $null }
    }
    # Unknown key layout: trust the recorded choice.
    if (-not $run) { return $true }
    $null -ne (Get-ItemProperty -LiteralPath $run -Name $name -ErrorAction SilentlyContinue)
}
foreach ($c in @($choices.startup)) {
    if (-not $c -or -not $c.approved_key -or -not $c.approved_name) { continue }
    if (-not (Test-StartupItemExists $c)) { continue }
    $v = (Get-ItemProperty -LiteralPath $c.approved_key -Name $c.approved_name -ErrorAction SilentlyContinue).($c.approved_name)
    if ($v -and ($v[0] -band 1)) { continue }  # still off
    try {
        if (-not (Test-Path -LiteralPath $c.approved_key)) { New-Item -Path $c.approved_key -Force | Out-Null }
        $bytes = [byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        New-ItemProperty -LiteralPath $c.approved_key -Name $c.approved_name -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        Write-Log "[startup] $($c.name): an update turned it back on - off again."
        $putBack++
    } catch {
        Write-Log "[startup] $($c.name): could not turn it off again: $($_.Exception.Message)"
        $failed++
    }
}

# --- Scheduled tasks ------------------------------------------------------------
foreach ($c in @($choices.tasks)) {
    if (-not $c -or -not $c.name) { continue }
    $task = Get-ScheduledTask -TaskPath $c.path -TaskName $c.name -ErrorAction SilentlyContinue
    if (-not $task -or "$($task.State)" -eq 'Disabled') { continue }
    try {
        Disable-ScheduledTask -TaskPath $c.path -TaskName $c.name -ErrorAction Stop | Out-Null
        Write-Log "[startup] Task $($c.name): an update turned it back on - disabled again."
        $putBack++
    } catch {
        Write-Log "[startup] Task $($c.name): could not disable it again: $($_.Exception.Message)"
        $failed++
    }
}

# --- Services -------------------------------------------------------------------
foreach ($c in @($choices.services)) {
    if (-not $c -or -not $c.name -or "$($c.start_mode)" -notin @('Manual', 'Disabled')) { continue }
    $svc = Get-Service -Name $c.name -ErrorAction SilentlyContinue
    if (-not $svc -or "$($svc.StartType)" -eq $c.start_mode) { continue }
    $was = "$($svc.StartType)"
    try {
        Set-Service -Name $c.name -StartupType $c.start_mode -ErrorAction Stop
        Write-Log "[startup] Service $($svc.DisplayName): an update set it to $was - back to $($c.start_mode)."
        $putBack++
    } catch {
        Write-Log "[startup] Service $($svc.DisplayName): could not set it back to $($c.start_mode): $($_.Exception.Message)"
        $failed++
    }
}

if ($putBack) {
    Write-Log "[startup] Put back $putBack of the $total startup choice(s) you made in Upkeep."
} elseif (-not $failed) {
    Write-Log "[startup] All $total startup choice(s) you made in Upkeep are still in place."
}
if ($failed) { exit 1 }
exit 0
