# Shared helpers for update steps that wrap a long-running program.
# Dot-source this file; it defines functions only.
#
# Every update step used to collect its child's output and print it once the
# child finished (ReadToEndAsync, Receive-Job | Out-String, reading the
# worker's redirect file after exit). One slow installer then meant 20-60
# silent minutes in the dashboard, which looked hung, and a run stopped in
# that window left neither the output nor the log behind.

# Appends one line to a log. Something else may have the file open at that
# instant (a viewer, antivirus, the dashboard reading it), so retry briefly,
# and never let a logging failure abort the update step itself.
function Add-LogLine {
    param([string]$LogFile, [AllowEmptyString()][string]$Line)
    if (-not $LogFile) { return }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds (40 * $attempt) }
    }
}

# Shows a line and appends it to the log right away.
function Write-StepLine {
    param([AllowEmptyString()][string]$Line, [string]$LogFile)
    Write-Host $Line
    Add-LogLine $LogFile $Line
}

function Format-Minutes {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -lt 1) { return '{0:N0}s' -f [math]::Floor($Span.TotalSeconds) }
    '{0:N0} min' -f [math]::Floor($Span.TotalMinutes)
}

# Runs a program, streaming stdout and stderr line by line as they arrive.
# Returns the program's exit code, or 1 on launch failure or timeout (the
# whole process tree is killed on timeout). Prints "[<Tag>] still running"
# after HeartbeatSec without output, so a quiet installer is visibly alive.
function Invoke-StreamedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$Tag,
        [string]$LogFile,
        [int]$TimeoutSec = 2700,
        [int]$HeartbeatSec = 300
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    try {
        $proc = [Diagnostics.Process]::Start($psi)
    } catch {
        Write-StepLine "[error] Could not start ${FilePath}: $($_.Exception.Message)" $LogFile
        return 1
    }

    $started = Get-Date
    $lastOutput = $started
    $deadline = $started.AddSeconds($TimeoutSec)
    $exitedAt = $null
    $timedOut = $false
    # One pending ReadLineAsync per pipe; a completed task with a $null
    # result is end-of-stream.
    $pipes = @(
        @{ Reader = $proc.StandardOutput; Task = $null; Done = $false },
        @{ Reader = $proc.StandardError; Task = $null; Done = $false }
    )

    while ($true) {
        $gotLine = $false
        foreach ($pipe in $pipes) {
            if ($pipe.Done) { continue }
            if ($null -eq $pipe.Task) { $pipe.Task = $pipe.Reader.ReadLineAsync() }
            if (-not $pipe.Task.IsCompleted) { continue }
            $line = $pipe.Task.Result
            $pipe.Task = $null
            if ($null -eq $line) {
                $pipe.Done = $true
            } else {
                Write-StepLine $line $LogFile
                $lastOutput = Get-Date
                $gotLine = $true
            }
        }
        if (-not @($pipes | Where-Object { -not $_.Done }).Count) { break }

        $now = Get-Date
        # A grandchild that inherited the pipes can hold them open after the
        # program itself exited; don't wait on it past a short drain grace.
        if ($proc.HasExited) {
            if ($null -eq $exitedAt) { $exitedAt = $now }
            if (($now - $exitedAt).TotalSeconds -ge 10) { break }
        }
        if ($now -ge $deadline) {
            Write-StepLine "[timeout] $Tag exceeded $(Format-Minutes ([TimeSpan]::FromSeconds($TimeoutSec))) - killing it and moving on." $LogFile
            try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch {}
            try { $proc.Kill() } catch {}
            $null = $proc.WaitForExit(5000)
            $timedOut = $true
            break
        }
        if (($now - $lastOutput).TotalSeconds -ge $HeartbeatSec) {
            Write-StepLine "[$Tag] still running ($(Format-Minutes ($now - $started)) elapsed, no output for $(Format-Minutes ($now - $lastOutput)))..." $LogFile
            $lastOutput = $now
        }
        if (-not $gotLine) { Start-Sleep -Milliseconds 100 }
    }

    if ($timedOut) { return 1 }
    $proc.WaitForExit()
    $code = $proc.ExitCode
    Write-StepLine "[$Tag] finished in $(Format-Minutes ((Get-Date) - $started)) (exit $code)." $LogFile
    return $code
}
