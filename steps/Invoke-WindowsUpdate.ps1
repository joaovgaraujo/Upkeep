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

    A failed pass is retried once (-Retries). A run on 2026-10-06 installed
    about twenty updates, then the job threw 0x80248007 (WU_E_DS_NODATA) and
    the whole step read "error". That code is usually transient, and a fresh
    scan installs whatever the first pass left. The first pass's errors are
    logged as [warn]; only a pass that fails for good logs [error]. A timeout
    is not retried: the time budget is already spent.

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
    [ValidateRange(0, 3)][int]$Retries = 1,
    # Tests substitute their own job body.
    [scriptblock]$JobBody = {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop -Verbose *>&1 |
            Out-String -Stream -Width 200
    }
)

. (Join-Path $PSScriptRoot 'Stream-Process.ps1')

$started = Get-Date
$deadline = $started.AddMinutes($TimeoutMin)

# One pass of the job. Returns 'ok', 'failed' or 'timeout'.
function Invoke-UpdatePass {
    param([bool]$Final)
    $job = Start-Job -ScriptBlock $JobBody
    $lastOutput = Get-Date
    $result = 'ok'

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
                return 'timeout'
            }
            if (($now - $lastOutput).TotalSeconds -ge $HeartbeatSec) {
                Write-StepLine "[winupdate] still running ($(Format-Minutes ($now - $started)) elapsed, no output for $(Format-Minutes ($now - $lastOutput)))..." $LogFile
                $lastOutput = $now
            }
            Start-Sleep -Seconds 2
        }
        $null = Receive-NewLines
        if ($job.State -eq 'Failed') {
            $result = 'failed'
            $tag = if ($Final) { '[error]' } else { '[warn]' }
            foreach ($child in $job.ChildJobs) {
                foreach ($err in $child.Error) { Write-StepLine "$tag $($err.Exception.Message)" $LogFile }
                if ($child.JobStateInfo.Reason) { Write-StepLine "$tag $($child.JobStateInfo.Reason.Message)" $LogFile }
            }
        }
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    $result
}

$attempt = 0
do {
    $final = $attempt -ge $Retries
    $result = Invoke-UpdatePass -Final $final
    if ($result -ne 'failed' -or $final) { break }
    $attempt++
    Write-StepLine "[winupdate] The Windows Update pass failed - scanning again for whatever it left (retry $attempt of $Retries)..." $LogFile
} while ($true)

$code = if ($result -eq 'ok') { 0 } else { 1 }
if ($result -eq 'failed') { Write-StepLine '[warn] Windows Update job failed - see the [error] lines above.' $LogFile }
elseif ($result -eq 'ok' -and $attempt -gt 0) { Write-StepLine '[winupdate] The retry completed; the earlier failure did not repeat.' $LogFile }
Write-StepLine "[winupdate] finished in $(Format-Minutes ((Get-Date) - $started)) ($(if ($code) { 'error' } else { 'ok' }))." $LogFile
exit $code
