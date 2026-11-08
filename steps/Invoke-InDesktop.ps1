<#
.SYNOPSIS
    Runs the update engine in the signed-in desktop session, for an engine
    started over SSH. Runs INSIDE the scheduled task that
    SystemUpdate_Topgrade.bat (:relay) registers.

.DESCRIPTION
    An SSH session has no desktop, and much of an update needs one:
      * winget, a packaged app, does not start there at all. Both the command
        alias and the real winget.exe fail with "Access is denied" (the test laptop,
        2026-11-07), so the first step stopped the run.
      * normal-user installs (steps\Deelevate.ps1) need the user's desktop.

    The SSH side is plain cmd.exe, with no Windows PowerShell. An SSH session
    reconnects the user's mapped network drives, and Windows PowerShell checks
    every drive when it starts: with a network drive's server down, the PowerShell
    that used to start this relay waited 9 minutes before doing anything
    (the test laptop, 2026-11-07). This task runs elevated in the desktop session,
    which does not see those drives.

    Files in -WorkDir, shared with the SSH side:
      env.txt        in   the run's DASHBOARD_*/UPKEEP_* settings (`set` output)
      started.txt    out  this task has started
      chunk_<n>.txt  out  the engine's output, complete lines, n = 1, 2, ...
      done.txt       out  the engine's exit code, written after the last chunk
#>
[CmdletBinding()]
param(
    # Default: the engine next to steps\. Not set in param(): Windows
    # PowerShell 5.1 leaves $PSScriptRoot empty there under -File.
    [string]$BatPath,
    [Parameter(Mandatory)][string]$WorkDir,
    # Tests: write the engine runner here and stop.
    [string]$WriteRunnerOnly
)
$ErrorActionPreference = 'Stop'
if (-not $BatPath) { $BatPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SystemUpdate_Topgrade.bat' }

$out = Join-Path $WorkDir 'out.txt'
$engineDone = Join-Path $WorkDir 'engine_done.txt'
$runner = if ($WriteRunnerOnly) { $WriteRunnerOnly } else { Join-Path $WorkDir 'run.ps1' }
if (-not $WriteRunnerOnly) { Set-Content -LiteralPath (Join-Path $WorkDir 'started.txt') -Value $PID -Encoding ascii }

# The run's own settings go with it; a task starts with the account's
# default environment.
$envLines = @()
$envFile = Join-Path $WorkDir 'env.txt'
if (Test-Path -LiteralPath $envFile) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^((?:DASHBOARD_|UPKEEP_)[A-Za-z0-9_]*)=(.*)$') {
            $envLines += "`$env:$($Matches[1]) = '$($Matches[2].Replace("'", "''"))'"
        }
    }
}
# The engine started over SSH keeps running SystemUpdate_Topgrade.bat while
# it waits; the engine lock must not take it for a second engine. It runs in
# another session (an SSH session is session 0); this task is in the desktop.
$session = (Get-Process -Id $PID).SessionId
$relayPids = @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -ne $session -and $_.CommandLine -match '(?i)SystemUpdate_Topgrade\.bat' } |
    ForEach-Object { $_.ProcessId })
$envLines += "`$env:UPKEEP_RELAY_PID = '$($relayPids -join ',')'"

$batLiteral = $BatPath.Replace("'", "''")
@"
`$env:DASHBOARD_RUN = '1'
$($envLines -join "`n")
`$env:UPKEEP_IN_DESKTOP = '1'
& cmd.exe /c ('"{0}" < NUL' -f '$batLiteral') *>&1 | ForEach-Object { `$_.ToString() | Out-File -FilePath '$($out.Replace("'", "''"))' -Append -Encoding utf8 }
`$code = `$LASTEXITCODE
if (`$null -eq `$code) { `$code = 1 }
Set-Content -LiteralPath '$($engineDone.Replace("'", "''"))' -Value `$code -Encoding ascii
"@ | Set-Content -LiteralPath $runner -Encoding UTF8
if ($WriteRunnerOnly) { exit 0 }

$utf8 = New-Object Text.UTF8Encoding($false)
$script:chunk = 0
function Write-Chunk([string]$Text) {
    if (-not $Text) { return }
    $script:chunk++
    $final = Join-Path $WorkDir "chunk_$($script:chunk).txt"
    # Written under another name, then renamed: the SSH side never sees half.
    [IO.File]::WriteAllText("$final.tmp", $Text, $utf8)
    Move-Item -LiteralPath "$final.tmp" -Destination $final -Force
}

$code = 1
try {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`"" | Out-Null
    $read = 0
    while ($true) {
        $finished = Test-Path -LiteralPath $engineDone
        if (Test-Path -LiteralPath $out) {
            try {
                $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -gt $read) {
                        [void]$fs.Seek($read, 'Begin')
                        $bytes = New-Object byte[] ($fs.Length - $read)
                        $n = $fs.Read($bytes, 0, $bytes.Length)
                        # Up to the last complete line; everything once the
                        # engine has finished.
                        $cut = if ($finished) { $n - 1 } else { [Array]::LastIndexOf($bytes, [byte]10, $n - 1) }
                        if ($cut -ge 0) {
                            Write-Chunk ([Text.Encoding]::UTF8.GetString($bytes, 0, $cut + 1).Replace([string][char]0xFEFF, ''))
                            $read += $cut + 1
                        }
                    }
                } finally { $fs.Dispose() }
            } catch {}
        }
        if ($finished) {
            [int]::TryParse(("$(Get-Content -LiteralPath $engineDone -TotalCount 1)").Trim(), [ref]$code) | Out-Null
            break
        }
        Start-Sleep -Milliseconds 700
    }
} catch {
    Write-Chunk "[remote] Could not run the update in the desktop session: $($_.Exception.Message)`r`n"
    $code = 1
} finally {
    Set-Content -LiteralPath (Join-Path $WorkDir 'done.txt') -Value $code -Encoding ascii
}
exit $code
