<#
.SYNOPSIS
    Waits for a step that was started in the background to finish.

.DESCRIPTION
    The client lane (Store, JDownloader, Steam) is started before the package
    managers so its downloads overlap the rest of the run, and joined here
    before the summary is printed. A `start /b` child gives cmd no handle to
    wait on, so the worker writes its own PID to -PidFile at startup and this
    step waits on that process.

    Treated as "already finished" rather than an error:
      - no PID file (the lane was never started, e.g. every client skipped),
      - a PID that is gone (the worker finished before the join),
      - a PID that belongs to something else entirely, which can happen after
        a reboot recycles PIDs; the start time in the PID file rules that out.

    The worker streams its own output to the log, so nothing is echoed here
    beyond a heartbeat - otherwise every line would appear twice.

    Exit code: 0 finished (or nothing to wait for), 1 timed out.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PidFile,
    [string]$LogFile,
    [string]$Tag = 'wait',
    [ValidateRange(1, 14400)][int]$TimeoutSec = 4200,
    [ValidateRange(1, 3600)][int]$HeartbeatSec = 300
)

. (Join-Path $PSScriptRoot 'Stream-Process.ps1')

$started = Get-Date

function Write-WaitLine {
    param([AllowEmptyString()][string]$Line)
    Write-StepLine "[$Tag] $Line" $LogFile
}

if (-not (Test-Path -LiteralPath $PidFile)) {
    # Nothing was started: every client was skipped, or the lane failed to
    # launch and its own step already reported that.
    exit 0
}

$raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
$fields = @("$raw".Trim() -split '\s+')
$workerPid = 0
if (-not [int]::TryParse($fields[0], [ref]$workerPid) -or $workerPid -le 0) {
    Write-WaitLine "[warn] $PidFile does not contain a PID - not waiting."
    exit 0
}

$process = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
if (-not $process) { exit 0 }

# A recycled PID would otherwise block the join on an unrelated process for
# the whole timeout. The worker records its start time next to its PID.
if ($fields.Count -gt 1) {
    $recorded = [datetime]::MinValue
    if ([datetime]::TryParse($fields[1], [ref]$recorded)) {
        if ([math]::Abs(($process.StartTime - $recorded).TotalSeconds) -gt 5) {
            Write-WaitLine "[warn] PID $workerPid is a different process now - not waiting."
            exit 0
        }
    }
}

Write-WaitLine 'Waiting for the background client updates to finish...'
$deadline = $started.AddSeconds($TimeoutSec)
$lastBeat = Get-Date
while (-not $process.HasExited) {
    if ((Get-Date) -ge $deadline) {
        Write-WaitLine "[timeout] The client lane exceeded $TimeoutSec seconds - moving on."
        # Killing it here would lose its result file; its own timeout handling
        # owns that decision.
        exit 1
    }
    if (((Get-Date) - $lastBeat).TotalSeconds -ge $HeartbeatSec) {
        Write-WaitLine "still finishing ($(Format-Minutes ((Get-Date) - $started)) waited)..."
        $lastBeat = Get-Date
    }
    Start-Sleep -Seconds 2
    $process.Refresh()
}

Write-WaitLine "Client updates finished (waited $(Format-Minutes ((Get-Date) - $started)))."
exit 0
