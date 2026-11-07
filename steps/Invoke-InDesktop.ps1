<#
.SYNOPSIS
    Runs the update engine in the signed-in desktop session when it was
    started over SSH, and streams its output back.

.DESCRIPTION
    An SSH session has no desktop, and much of an update needs one:
      * winget, a packaged app, does not start there at all. Both the command
        alias and the real winget.exe fail with "Access is denied" (the test laptop,
        2026-11-07), so the first step stopped the run.
      * normal-user installs (steps\Deelevate.ps1) need the user's desktop.
    This registers a one-off scheduled task for the same account, elevated
    (RunLevel Highest) and Interactive, so it runs in the session where that
    account is signed in. The task runs the engine with output to a file,
    which is printed here as it grows. Exit code: the engine's.

    The account must be signed in to Windows (at the PC or over Remote
    Desktop). Stopping the SSH command does not stop the run; stop it from
    the Upkeep window or end the task "Upkeep_Desktop_*".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BatPath,
    [ValidateRange(1, 1440)][int]$TimeoutMin = 360
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deelevate.ps1')

try { $sid = Get-DeelevatedUserSid }
catch {
    Write-Host '[remote] Started over SSH, and this account is not signed in to Windows. Sign in (at the PC or over Remote Desktop) and run it again: winget and normal-user updates only work in a desktop session.'
    exit 1
}

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $env:TEMP "Upkeep_desktop_$tag"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$out = Join-Path $work 'out.txt'
$done = Join-Path $work 'done.txt'
$runner = Join-Path $work 'run.ps1'
$taskName = "Upkeep_Desktop_$tag"

# The run's own settings (DASHBOARD_*, UPKEEP_*) go with it; a task starts
# with the account's default environment.
$envLines = Get-ChildItem Env: | Where-Object { $_.Name -match '^(DASHBOARD_|UPKEEP_)' } |
    ForEach-Object { "`$env:$($_.Name) = '$($_.Value.Replace("'", "''"))'" }
$batLiteral = $BatPath.Replace("'", "''")
# The calling cmd.exe keeps running SystemUpdate_Topgrade.bat while it
# waits; the engine lock must not take it for a second engine.
$relayPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
$envLines = @($envLines) + "`$env:UPKEEP_RELAY_PID = '$relayPid'"
@"
`$env:DASHBOARD_RUN = '1'
$($envLines -join "`n")
`$env:UPKEEP_IN_DESKTOP = '1'
& cmd.exe /c ('"{0}" < NUL' -f '$batLiteral') *>&1 | ForEach-Object { `$_.ToString() | Out-File -FilePath '$($out.Replace("'", "''"))' -Append -Encoding utf8 }
`$code = `$LASTEXITCODE
if (`$null -eq `$code) { `$code = 1 }
Set-Content -LiteralPath '$($done.Replace("'", "''"))' -Value `$code -Encoding ascii
"@ | Set-Content -LiteralPath $runner -Encoding UTF8

$code = 1
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes($TimeoutMin))
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host '[remote] Started over SSH: running the update in your desktop session, where winget works. Output follows.'

    $read = 0
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        if (Test-Path -LiteralPath $out) {
            try {
                $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -gt $read) {
                        [void]$fs.Seek($read, 'Begin')
                        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                        $chunk = $sr.ReadToEnd()
                        $read = $fs.Length
                        # Hold back a partial last line until it is complete.
                        $cut = $chunk.LastIndexOf("`n")
                        if ($cut -ge 0) {
                            [Console]::Out.Write($chunk.Substring(0, $cut + 1).TrimStart([char]0xFEFF))
                            $read -= [Text.Encoding]::UTF8.GetByteCount($chunk.Substring($cut + 1))
                        } else { $read -= [Text.Encoding]::UTF8.GetByteCount($chunk) }
                    }
                } finally { $fs.Dispose() }
            } catch {}
        }
        if (Test-Path -LiteralPath $done) {
            Start-Sleep -Milliseconds 500
            if (Test-Path -LiteralPath $out) {
                $all = [IO.File]::ReadAllBytes($out)
                if ($all.Length -gt $read) { [Console]::Out.Write([Text.Encoding]::UTF8.GetString($all, $read, $all.Length - $read)) }
            }
            [int]::TryParse(("$(Get-Content -LiteralPath $done -TotalCount 1)").Trim(), [ref]$code) | Out-Null
            break
        }
    }
    if (-not (Test-Path -LiteralPath $done)) { Write-Host "[remote] No result after $TimeoutMin min; the run may still be going in the desktop session (task $taskName)." }
} catch {
    Write-Host "[remote] Could not start the update in the desktop session: $($_.Exception.Message)"
    $code = 1
} finally {
    if (Test-Path -LiteralPath $done) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $code
