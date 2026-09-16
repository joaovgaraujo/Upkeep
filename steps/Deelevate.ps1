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

function Invoke-Deelevated {
    <#
    .PARAMETER Command
        PowerShell command text to run unelevated. A native command's exit code
        is captured via $LASTEXITCODE.

    .PARAMETER TimeoutSec
        Give up waiting after this long. The child is NOT killed on timeout --
        an installer mid-write is worse interrupted than left alone.

    .OUTPUTS
        [pscustomobject] with ExitCode and Output, or $null when the command
        could not be run unelevated at all (caller should fall back).
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

    try {
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null

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
$Command
}
try {
    & `$cmd *>&1 | Out-File -FilePath '$outFile' -Encoding utf8
    `$code = `$LASTEXITCODE
} catch {
    `$_ | Out-File -FilePath '$outFile' -Append -Encoding utf8
    `$code = 1
}
if (`$null -eq `$code) { `$code = 0 }
Set-Content -Path '$doneFile' -Value `$code -Encoding ascii
"@
        Set-Content -Path $runner -Value $body -Encoding UTF8 -ErrorAction Stop

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
        # UAC elevation does not change the user, only the integrity level, so
        # the same account at RunLevel Limited is the unelevated us.
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $doneFile) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $doneFile)) { return $null }

        $code = 0
        $raw = (Get-Content -LiteralPath $doneFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        [void][int]::TryParse(("$raw").Trim(), [ref]$code)

        $text = ''
        if (Test-Path -LiteralPath $outFile) {
            $text = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }

        [pscustomobject]@{ ExitCode = $code; Output = "$text" }
    } catch {
        return $null
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
