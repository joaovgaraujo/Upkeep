<#
.SYNOPSIS
    Runs topgrade with a watchdog, streaming its output line by line.

.DESCRIPTION
    The inline wrapper this replaces read both pipes with ReadToEndAsync and
    printed them only after topgrade exited, so the dashboard showed nothing
    for up to TimeoutMin minutes and a run stopped mid-way lost all of it.
    Here each line is shown and appended to the log as soon as it arrives,
    and a heartbeat line marks long silent stretches (a slow installer inside
    topgrade) so they don't look like a hang.

    Exit code: topgrade's own exit status, or 1 on timeout / launch failure.

.PARAMETER ConfigPath
    topgrade config passed via --config.

.PARAMETER LogFile
    Optional log to append every line to.

.PARAMETER TimeoutMin
    Kill topgrade (whole tree) after this many minutes.

.PARAMETER HeartbeatSec
    Print a "still running" line after this many seconds without output.

.PARAMETER Executable
    Program to run; tests substitute a fake.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$LogFile,
    [ValidateRange(1, 600)][int]$TimeoutMin = 45,
    [ValidateRange(1, 3600)][int]$HeartbeatSec = 300,
    [string]$Executable = 'topgrade',
    [string]$ExtraArguments = ''
)

. (Join-Path $PSScriptRoot 'Stream-Process.ps1')

$arguments = '--config "' + $ConfigPath + '"'
if ($ExtraArguments) { $arguments = "$arguments $ExtraArguments" }
$code = Invoke-StreamedProcess -FilePath $Executable -Arguments $arguments -Tag 'topgrade' `
    -LogFile $LogFile -TimeoutSec ($TimeoutMin * 60) -HeartbeatSec $HeartbeatSec
exit $code
