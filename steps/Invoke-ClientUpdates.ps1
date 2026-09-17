# Run independent client updaters AFTER package managers and Windows servicing.
# Child processes stay in the engine's process tree, so the GUI Stop kills them.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$LogFile,
    [ValidateRange(1,3)][int]$MaxParallel = 3,
    [ValidateRange(1,7200)][int]$TimeoutSec = 3900
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
function Write-ClientLog([string]$Line) {
    Write-Host $Line
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 }
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
                $null = $active.Add(@{ Spec=$spec; Process=$proc; Out=$out; Err=$err; Started=[datetime]::UtcNow })
                Write-ClientLog "[clients] Started $($spec.Name)."
                Write-ClientLog "[$($spec.Tag)] Update worker running."
            } catch { Write-ClientLog "[error] $($spec.Name): $_" }
        }
        foreach ($worker in @($active.ToArray())) {
            $proc = $worker.Process
            $timedOut = ([datetime]::UtcNow - $worker.Started).TotalSeconds -ge $TimeoutSec
            if (-not $proc.HasExited -and -not $timedOut) { continue }
            if (-not $proc.HasExited) {
                & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
                $null = $proc.WaitForExit(5000)
                Write-ClientLog "[timeout] $($worker.Spec.Name) exceeded $TimeoutSec seconds."
            } else {
                $results[$worker.Spec.Name] = switch ($proc.ExitCode) { 0 {'ok'} 2 {'skipped'} default {'error'} }
            }
            foreach ($path in @($worker.Out, $worker.Err)) {
                if (Test-Path -LiteralPath $path) {
                    foreach ($line in Get-Content -LiteralPath $path) { Write-ClientLog $line }
                }
            }
            Write-ClientLog "[clients] $($worker.Spec.Name): $($results[$worker.Spec.Name])"
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
