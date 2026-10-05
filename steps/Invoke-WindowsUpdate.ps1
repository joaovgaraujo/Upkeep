<#
.SYNOPSIS
    Installs Windows updates via PSWindowsUpdate with a watchdog, streaming
    progress as it happens.

.DESCRIPTION
    topgrade folds Windows Update into its "system" step, which it silently
    SKIPS on this machine, so the update run calls PSWindowsUpdate directly.

    Runs as a background job so Stop-Job reliably tears down its worker.
    Output used to be `| Out-String`-ed inside the job and received once at
    the end - up to TimeoutMin silent minutes. Now the job emits formatted
    lines as they are produced (Out-String -Stream) and this script pulls
    them every couple of seconds, with a heartbeat during long downloads.

    -ExecutionPolicy Bypass on the calling powershell.exe is REQUIRED: with
    no execution policy set (Restricted), Import-Module PSWindowsUpdate cannot
    load its .psm1 inside the job.

    Exit code: 0 ok, 1 failed or timed out.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [ValidateRange(1, 600)][int]$TimeoutMin = 40,
    [ValidateRange(1, 3600)][int]$HeartbeatSec = 300,
    # Tests substitute their own job body.
    [scriptblock]$JobBody = {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop -Verbose *>&1 |
            Out-String -Stream -Width 200
    }
)

. (Join-Path $PSScriptRoot 'Stream-Process.ps1')

$job = Start-Job -ScriptBlock $JobBody
$started = Get-Date
$lastOutput = $started
$deadline = $started.AddMinutes($TimeoutMin)
$code = 0

function Receive-NewLines {
    $got = $false
    foreach ($item in @(Receive-Job $job -ErrorAction SilentlyContinue)) {
        $text = "$item".TrimEnd()
        if ($text) { Write-StepLine $text $LogFile; $got = $true }
    }
    $got
}

try {
    while ($job.State -in @('NotStarted', 'Running')) {
        if (Receive-NewLines) { $lastOutput = Get-Date }
        $now = Get-Date
        if ($now -ge $deadline) {
            Write-StepLine "[timeout] Windows Update exceeded $TimeoutMin minutes - moving on." $LogFile
            $code = 1
            break
        }
        if (($now - $lastOutput).TotalSeconds -ge $HeartbeatSec) {
            Write-StepLine "[winupdate] still running ($(Format-Minutes ($now - $started)) elapsed, no output for $(Format-Minutes ($now - $lastOutput)))..." $LogFile
            $lastOutput = $now
        }
        Start-Sleep -Seconds 2
    }
    if ($code -eq 0) {
        $null = Receive-NewLines
        if ($job.State -eq 'Failed') {
            $code = 1
            foreach ($child in $job.ChildJobs) {
                foreach ($err in $child.Error) { Write-StepLine "[error] $($err.Exception.Message)" $LogFile }
                if ($child.JobStateInfo.Reason) { Write-StepLine "[error] $($child.JobStateInfo.Reason.Message)" $LogFile }
            }
            Write-StepLine '[warn] Windows Update job failed - see the [error] lines above.' $LogFile
        }
    }
} finally {
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}
Write-StepLine "[winupdate] finished in $(Format-Minutes ((Get-Date) - $started)) ($(if ($code) { 'error' } else { 'ok' }))." $LogFile
exit $code
