# Run independent client updaters AFTER package managers and Windows servicing.
# Child processes stay in the engine's process tree, so the GUI Stop kills them.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$LogFile,
    [ValidateRange(1,3)][int]$MaxParallel = 3,
    [ValidateRange(1,7200)][int]$TimeoutSec = 3900,
    [ValidateRange(1,3600)][int]$HeartbeatSec = 300
)
$ErrorActionPreference = 'Stop'
$skipJDownloader = if ($env:DASHBOARD_SKIP_OTHER_APPS -eq '1') { '1' } else { $env:DASHBOARD_SKIP_APPS }
$specs = @(
    @{ Name='STORE'; Tag='store'; Script='Update-StoreApps.ps1'; Skip=$env:DASHBOARD_SKIP_STORE },
    @{ Name='JD'; Tag='jdownloader'; Script='Update-JDownloader.ps1'; Skip=$skipJDownloader },
    @{ Name='STEAM'; Tag='steam'; Script='Update-SteamGames.ps1'; Skip=$env:DASHBOARD_SKIP_STEAM }
)
$results = [ordered]@{ STORE='skipped'; JD='skipped'; STEAM='skipped' }
$pending = [Collections.Queue]::new()
foreach ($spec in $specs) { if ($spec.Skip -ne '1') { $pending.Enqueue($spec) } }
$active = [Collections.ArrayList]::new()
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('Upkeep-clients-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($scratch) | Out-Null
. (Join-Path $PSScriptRoot 'Stream-Process.ps1')
# Under $ErrorActionPreference='Stop' a bare Add-Content used to throw when
# anything had the log open, killing every client worker with exit 1.
function Write-ClientLog([string]$Line) {
    Write-Host $Line
    Add-LogLine $LogFile $Line
}
# Workers' output used to be read only after each one exited - up to
# TimeoutSec silent minutes (Steam patching a big game). Tail the redirect
# files instead: forward complete lines as they appear, keeping a partial
# trailing line until its newline arrives. The files are shared for writing
# by the worker, so open them ReadWrite.
function Read-WorkerOutput($Worker, [switch]$Final) {
    foreach ($key in 'Out', 'Err') {
        $path = $Worker[$key]
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $stream = $null
        try {
            $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $offsetKey = $key + 'Offset'
            $pendingKey = $key + 'Pending'
            if ($stream.Length -le $Worker[$offsetKey]) { $text = '' } else {
                $null = $stream.Seek($Worker[$offsetKey], 'Begin')
                $bytes = New-Object byte[] ($stream.Length - $Worker[$offsetKey])
                $read = $stream.Read($bytes, 0, $bytes.Length)
                $Worker[$offsetKey] += $read
                $text = [Text.Encoding]::Default.GetString($bytes, 0, $read)
            }
            $text = $Worker[$pendingKey] + $text
            $parts = $text -split "`r?`n"
            $Worker[$pendingKey] = if ($Final) { '' } else { $parts[-1] }
            # Not $parts[0..($parts.Count - 2)]: with one part that is 0..-1,
            # which selects the partial line itself (twice).
            $complete = if ($Final) { $parts } elseif ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] } else { @() }
            foreach ($line in $complete) { if ($line -ne '') { Write-ClientLog $line; $Worker.LastOutput = [datetime]::UtcNow } }
        } catch {
            # The worker may be mid-write; the next poll picks it up.
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
}
try {
    while ($pending.Count -or $active.Count) {
        while ($pending.Count -and $active.Count -lt $MaxParallel) {
            $spec = $pending.Dequeue()
            $results[$spec.Name] = 'error'
            $out = Join-Path $scratch ($spec.Name + '.out')
            $err = Join-Path $scratch ($spec.Name + '.err')
            try {
                $script = Join-Path $PSScriptRoot $spec.Script
                if (-not (Test-Path -LiteralPath $script)) { throw "Missing worker: $script" }
                $proc = Start-Process -FilePath "$PSHOME\powershell.exe" -WindowStyle Hidden -PassThru `
                    -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"') `
                    -RedirectStandardOutput $out -RedirectStandardError $err
                # Force acquisition of a process handle before it exits.
                $null = $proc.Handle
                $now = [datetime]::UtcNow
                $null = $active.Add(@{ Spec=$spec; Process=$proc; Out=$out; Err=$err; Started=$now; LastOutput=$now; Heartbeat=$now
                    OutOffset=0L; ErrOffset=0L; OutPending=''; ErrPending='' })
                Write-ClientLog "[clients] Started $($spec.Name)."
                Write-ClientLog "[$($spec.Tag)] Update worker running."
            } catch { Write-ClientLog "[error] $($spec.Name): $_" }
        }
        foreach ($worker in @($active.ToArray())) {
            $proc = $worker.Process
            Read-WorkerOutput $worker
            $now = [datetime]::UtcNow
            $timedOut = ($now - $worker.Started).TotalSeconds -ge $TimeoutSec
            if (-not $proc.HasExited -and -not $timedOut) {
                $quiet = $now - (@($worker.LastOutput, $worker.Heartbeat) | Sort-Object)[-1]
                if ($quiet.TotalSeconds -ge $HeartbeatSec) {
                    Write-ClientLog ("[{0}] still running ({1:N0} min elapsed)..." -f $worker.Spec.Tag, [math]::Floor(($now - $worker.Started).TotalMinutes))
                    $worker.Heartbeat = $now
                }
                continue
            }
            if (-not $proc.HasExited) {
                & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
                $null = $proc.WaitForExit(5000)
                Write-ClientLog "[timeout] $($worker.Spec.Name) exceeded $TimeoutSec seconds."
            } else {
                $results[$worker.Spec.Name] = switch ($proc.ExitCode) { 0 {'ok'} 2 {'skipped'} default {'error'} }
            }
            Read-WorkerOutput $worker -Final
            Write-ClientLog ("[clients] {0}: {1} (after {2:N0} min)" -f $worker.Spec.Name, $results[$worker.Spec.Name], [math]::Floor(([datetime]::UtcNow - $worker.Started).TotalMinutes))
            $proc.Dispose()
            $active.Remove($worker)
        }
        if ($active.Count) { Start-Sleep -Milliseconds 200 }
    }
} finally {
    foreach ($worker in $active) {
        if (-not $worker.Process.HasExited) { & taskkill.exe /T /F /PID $worker.Process.Id 2>&1 | Out-Null }
        $worker.Process.Dispose()
    }
    # Only remove the GUID directory created by this invocation.
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
$results.GetEnumerator() | ForEach-Object { "$($_.Key)_STATUS=$($_.Value)" } |
    Set-Content -LiteralPath $ResultFile -Encoding ASCII
if ($results.Values -contains 'error') { exit 1 }
exit 0
