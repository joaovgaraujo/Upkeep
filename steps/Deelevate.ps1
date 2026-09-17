<#
.SYNOPSIS
    Runs a command as the logged-on user at MEDIUM integrity, from an elevated
    script, and returns its exit code and output.

.DESCRIPTION
    Dot-source this to get Test-Elevated and Invoke-Deelevated.

    The engine runs elevated so it can install machine-scope packages. That
    breaks the opposite case: winget REFUSES to touch a user-scope package
    while running as administrator ("The package installed for user scope
    cannot be uninstalled when running with administrator privileges",
    0x8A15007D / -1978335107), so those packages sit un-upgraded run after run.

    steps\Start-Launchers.ps1 already solved the "start something unelevated"
    half of this with a scheduled task registered with an Interactive principal
    at RunLevel Limited. That one is fire-and-forget: it returns as soon as a
    process appears, because a launcher's exit code is meaningless to us.
    A package upgrade is the opposite -- the exit code IS the result -- so this
    variant waits for completion and captures both.

    Completion is detected with a sentinel file rather than the task's State or
    LastTaskResult. Start-ScheduledTask is asynchronous and the task briefly
    reads Ready before it reads Running, so polling State races the start and
    reports "finished" against a task that never ran.

.NOTES
    The command runs in a SEPARATE PowerShell process, so it sees none of the
    caller's variables or functions. Pass everything it needs inline.
#>

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RequiresNormalUser {
    param([int]$ExitCode, [string]$Output)
    # WinGet ADMIN_CONTEXT_ACTION_PROHIBITED and INSTALLER_PROHIBITS_ELEVATION.
    $ExitCode -in @(-1978335107, -1978335146) -or
        $Output -match 'user scope cannot be uninstalled when running with administrator|installer cannot be run from an administrator context'
}

function Get-DeelevatedUserSid {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = (Get-Process -Id $PID).SessionId
    $shells = @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $session })
    foreach ($shell in $shells) {
        $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $sid) { return $sid }
    }
    throw 'No desktop session for this account. Open Upkeep from your usual Windows account; do not use another administrator account for user-app updates.'
}

function Invoke-Deelevated {
    <#
    .PARAMETER Command
        PowerShell command text to run unelevated. A native command's exit code
        is captured via $LASTEXITCODE.

    .PARAMETER TimeoutSec
        Give up waiting after this long. The child is NOT killed on timeout --
        an installer mid-write is worse interrupted than left alone.

    .OUTPUTS
        [pscustomobject] with Status, ExitCode and Output. TimedOut means the
        installer may still be running; never start a second attempt.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 900
    )

    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $work = Join-Path $env:TEMP "Upkeep_deelev_$tag"
    $runner = Join-Path $work 'run.ps1'
    $outFile = Join-Path $work 'out.txt'
    $doneFile = Join-Path $work 'done.txt'
    $taskName = "Upkeep_Deelev_$tag"
    $started = $false
    $completed = $false

    try {
        $userSid = Get-DeelevatedUserSid
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
        $outLiteral = $outFile.Replace("'", "''")
        $doneLiteral = $doneFile.Replace("'", "''")

        # *>&1 so stderr lands in the transcript too: winget writes some of its
        # refusals there, and those are exactly the lines we need to classify.
        # The exit code is written LAST so its presence means "really finished".
        # The command goes inside a script block so that a multi-statement
        # command still redirects as ONE unit. Interpolating it bare in front of
        # `*>&1 | Out-File` binds the redirect to its LAST statement only, which
        # silently drops the output of everything before it -- and empty output
        # is exactly what makes a caller misclassify the result.
        $body = @"
`$ErrorActionPreference = 'Continue'
`$cmd = {
`$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
`$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
if (`$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Windows did not provide a non-admin token. Installer was not started.'
}
$Command
}
try {
    & `$cmd *>&1 | Out-File -FilePath '$outLiteral' -Encoding utf8
    `$code = `$LASTEXITCODE
} catch {
    `$_ | Out-File -FilePath '$outLiteral' -Append -Encoding utf8
    `$code = 1
}
if (`$null -eq `$code) { `$code = 1 }
Set-Content -LiteralPath '$doneLiteral' -Value `$code -Encoding ascii
"@
        Set-Content -Path $runner -Value $body -Encoding UTF8 -ErrorAction Stop

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
        # UAC elevation does not change the user, only the integrity level, so
        # the same account at RunLevel Limited is the unelevated us.
        $principal = New-ScheduledTaskPrincipal `
            -UserId $userSid `
            -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $started = $true

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $doneFile) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $doneFile)) {
            return [pscustomobject]@{ Status = 'TimedOut'; ExitCode = 1; Output = "Normal-user installer has not finished after ${TimeoutSec}s and may still be running. No second attempt was started. Wait before retrying. Diagnostics: $work (task $taskName)." }
        }
        $completed = $true

        $code = 0
        $raw = (Get-Content -LiteralPath $doneFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not [int]::TryParse(("$raw").Trim(), [ref]$code)) { throw 'Normal-user worker returned an invalid exit code; result is unknown.' }

        $text = ''
        if (Test-Path -LiteralPath $outFile) {
            $text = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }

        [pscustomobject]@{ Status = 'Completed'; ExitCode = $code; Output = "$text" }
    } catch {
        return [pscustomobject]@{ Status = 'Unavailable'; ExitCode = 1; Output = "Could not run as normal user: $($_.Exception.Message)" }
    } finally {
        if (-not $started -or $completed) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            # Only this invocation's generated directory beneath TEMP is removed.
            $resolved = [IO.Path]::GetFullPath($work)
            $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolved) -eq "Upkeep_deelev_$tag") {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
