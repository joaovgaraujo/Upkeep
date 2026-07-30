<#
.SYNOPSIS
    Starts the game/chat launchers in the background so they self-update
    without stealing focus.

.DESCRIPTION
    Replaces the two ad-hoc `Start-Process` blocks that used to live in
    SystemUpdate_Topgrade.bat. Every launcher is started the quietest way it
    supports:

      * Steam, Epic and Discord have real "start to tray / start minimized"
        switches, used by their own autostart entries:
            steam.exe            -silent
            EpicGamesLauncher.exe -silent
            Update.exe           --processStart Discord.exe
                                 --process-start-args --start-minimized
      * The EA app and Battle.net have no such switch (verified by scanning
        EADesktop.exe/EALauncher.exe for command-line tokens: silent start is
        an in-app setting, not a CLI flag). For those we start the process and
        then minimize whatever top-level window it puts up.

    The minimize pass runs for every launcher, not just the flagless ones --
    the flags are best-effort and a launcher that decides to show its window
    anyway (first run after an update, a login prompt) would otherwise jump in
    front of whatever the user is doing. Windows are MINIMIZED, never hidden,
    so anything without a tray icon is still reachable from the taskbar.

.NOTES
    Launchers inherit this script's elevation. That is pre-existing behaviour
    (the engine runs elevated so it can install updates), but it does mean
    Steam/Epic run as admin for the session they were started in.

.PARAMETER SettleSec
    How long to keep watching for windows to minimize after the last launcher
    starts. Launchers can take a while to paint their first window.

.PARAMETER Only
    Restrict the run to named launchers (Steam, EA, Epic, Discord, Battlenet).
    Mainly for testing.
#>
[CmdletBinding()]
param(
    [int]$SettleSec = 25,
    [string[]]$Only
)

$ErrorActionPreference = 'Continue'

# `powershell -File script.ps1 -Only EA,Epic` does NOT split on commas the way
# `-Command` does: PS 5.1 binds the whole thing as the single string
# "EA,Epic", which matches no launcher key and silently starts nothing.
# Normalize here so the script behaves the same under -File and -Command.
$KnownKeys = @('Steam', 'EA', 'Epic', 'Discord', 'Battlenet')
if ($Only) {
    $Only = @($Only |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })

    $unknown = @($Only | Where-Object { $KnownKeys -notcontains $_ })
    if ($unknown) {
        Write-Host "[launch] Unknown launcher name(s): $($unknown -join ', '). Known: $($KnownKeys -join ', ')."
    }
    if (-not ($Only | Where-Object { $KnownKeys -contains $_ })) {
        # Refuse to exit 0 pretending all was well - that is exactly how the
        # comma-binding bug above hid itself.
        Write-Host '[launch] -Only matched no known launcher - nothing would run. Check the caller.'
        exit 1
    }
}

# --- Win32: minimize a process's top-level windows ------------------------
# ShowWindowAsync (not ShowWindow) so a launcher that is busy pumping its
# splash screen can't block us. SW_MINIMIZE = 6.
if (-not ('UpkeepWin32' -as [type])) {
    Add-Type -Namespace '' -Name 'UpkeepWin32' -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
}

# Process IDs whose windows we want kept out of the way, plus the names they
# spawn their real UI under (EALauncher hands off to EADesktop, Discord's
# Update.exe hands off to Discord.exe, ...).
$script:WatchPids = New-Object System.Collections.Generic.HashSet[int]
$script:WatchNames = New-Object System.Collections.Generic.HashSet[string]
# Launchers that were present on disk but refused to start. Reported through
# the exit code so the engine can surface it instead of silently claiming ok.
$script:FailedCount = 0

function Minimize-WatchedWindows {
    if (-not ('UpkeepWin32' -as [type])) { return 0 }

    # Refresh: pick up UI processes started by the launchers themselves.
    $pids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($p in $script:WatchPids) { [void]$pids.Add($p) }
    foreach ($name in $script:WatchNames) {
        foreach ($proc in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            [void]$pids.Add($proc.Id)
        }
    }
    if ($pids.Count -eq 0) { return 0 }

    $count = 0
    $callback = [UpkeepWin32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $owner = 0
        [void][UpkeepWin32]::GetWindowThreadProcessId($hWnd, [ref]$owner)
        if ($pids.Contains([int]$owner) -and
            [UpkeepWin32]::IsWindowVisible($hWnd) -and
            -not [UpkeepWin32]::IsIconic($hWnd) -and
            # GW_OWNER = 4: skip owned dialogs, minimize only real top-level
            # windows (minimizing a modal child can wedge the parent).
            [UpkeepWin32]::GetWindow($hWnd, 4) -eq [IntPtr]::Zero) {
            [void][UpkeepWin32]::ShowWindowAsync($hWnd, 6)
            $script:MinimizedThisPass++
        }
        return $true
    }
    $script:MinimizedThisPass = 0
    [void][UpkeepWin32]::EnumWindows($callback, [IntPtr]::Zero)
    $count = $script:MinimizedThisPass
    return $count
}

function Start-Deelevated {
    <#
    .SYNOPSIS
        Starts a process as the logged-on user at MEDIUM integrity, from this
        elevated script.
    .DESCRIPTION
        The engine runs elevated, so anything it Start-Process'es inherits a
        high-integrity token. That handed administrator rights to Steam, EA,
        Epic and Discord -- and to every game launched from them -- for the
        whole session, which is both unnecessary and a real escalation surface
        (their updaters live in user-writable paths).

        A scheduled task registered with an Interactive principal at RunLevel
        Limited runs as the same user WITHOUT elevation, and unlike the
        explorer.exe trick it passes arguments through intact -- which matters,
        because Steam's -silent and Discord's --processStart ARE the feature.

        Returns $true if the process was started de-elevated. Callers fall
        back to an ordinary elevated Start-Process on $false, because a
        launcher that starts with too many rights still beats one that does
        not start.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        # Process name to wait for, so we know the task actually spawned
        # something before we delete it.
        [string]$WaitFor
    )

    $taskName = "Upkeep_Launch_$([IO.Path]::GetFileNameWithoutExtension($Exe))_$PID"
    try {
        # Quote only what needs it; Register-ScheduledTask takes one string.
        $argStr = ($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '

        $action = if ($argStr) {
            New-ScheduledTaskAction -Execute $Exe -Argument $argStr
        } else {
            New-ScheduledTaskAction -Execute $Exe
        }

        # Same account as this process (UAC elevation does not change the
        # user, only the integrity level), so Interactive+Limited lands the
        # process on the user's desktop unelevated.
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # Start-ScheduledTask is asynchronous. Deleting the task does not kill
        # an already-spawned child, but deleting it BEFORE the engine spawns
        # anything would, so wait for evidence of a process first.
        if ($WaitFor) {
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                if (Get-Process -Name $WaitFor -ErrorAction SilentlyContinue) { break }
                Start-Sleep -Milliseconds 250
            }
        } else {
            Start-Sleep -Seconds 2
        }
        return $true
    } catch {
        Write-Host "[launch]   de-elevation unavailable ($($_.Exception.Message.Trim())); falling back to elevated start."
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Start-Launcher {
    param(
        [string]$Key,
        [string]$Label,
        [string[]]$Paths,
        [string[]]$Arguments = @(),
        # Process names to keep minimizing after launch (the UI may be a
        # different process than the one we started).
        [string[]]$UiProcesses = @(),
        # Skip if this process is already running -- relaunching a live
        # launcher pops its window to the front, the exact thing we're
        # avoiding.
        [string[]]$AlreadyRunning = @()
    )

    if ($Only -and ($Only -notcontains $Key)) { return }

    $exe = $Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $exe) {
        Write-Host "[launch] $Label not installed - skipping."
        return
    }

    foreach ($name in $AlreadyRunning) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            # Deliberately does NOT register the process for the minimize
            # pass. "Leaving it alone" has to mean it: if the user has Steam
            # or Discord open and is looking at it, yanking the window to the
            # taskbar mid-session is worse than the popup we're avoiding.
            Write-Host "[launch] $Label already running - leaving it alone."
            return
        }
    }

    try {
        $shown = if ($Arguments.Count -gt 0) { " $($Arguments -join ' ')" } else { '' }
        $ownName = [IO.Path]::GetFileNameWithoutExtension($exe)

        # Preferred path: start it WITHOUT our elevation. The scheduled-task
        # route gives us no PID, so the minimize pass watches by process name
        # instead -- which it already supports for the launchers whose UI is a
        # different process than the one we start.
        if (Start-Deelevated -Exe $exe -Arguments $Arguments -WaitFor $ownName) {
            [void]$script:WatchNames.Add($ownName)
            foreach ($n in $UiProcesses) { [void]$script:WatchNames.Add($n) }
            Write-Host "[launch] Started $Label in the background, unelevated.$shown"
            return
        }

        $splat = @{
            FilePath     = $exe
            WindowStyle  = 'Minimized'
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        if ($Arguments.Count -gt 0) { $splat.ArgumentList = $Arguments }
        $proc = Start-Process @splat
        [void]$script:WatchPids.Add($proc.Id)
        foreach ($n in $UiProcesses) { [void]$script:WatchNames.Add($n) }
        Write-Host "[launch] Started $Label in the background.$shown"
    } catch {
        Write-Host "[launch] Could not start $($Label): $($_.Exception.Message)"
        $script:FailedCount++
    }
}

$programFiles = ${env:ProgramFiles}
$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) { $programFilesX86 = $programFiles }

Write-Host '[launch] Starting game/chat clients in the background...'

# Steam: -silent is Steam's own "start in tray" switch (same one
# steps\Update-SteamGames.ps1 uses when it relaunches Steam).
Start-Launcher -Key 'Steam' -Label 'Steam' -Arguments @('-silent') `
    -Paths @(
        (Join-Path $programFilesX86 'Steam\steam.exe'),
        (Join-Path $programFiles 'Steam\steam.exe')
    ) -UiProcesses @('steam') -AlreadyRunning @('steam')

# EA app: no silent switch exists, so this one relies on the minimize pass.
Start-Launcher -Key 'EA' -Label 'EA app' `
    -Paths @(
        (Join-Path $programFiles 'Electronic Arts\EA Desktop\EA Desktop\EALauncher.exe'),
        (Join-Path $programFiles 'Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe')
    ) -UiProcesses @('EADesktop', 'EALauncher') -AlreadyRunning @('EADesktop')

# Epic: -silent is what Epic's own "run at startup" entry uses.
Start-Launcher -Key 'Epic' -Label 'Epic Games Launcher' -Arguments @('-silent') `
    -Paths @(
        (Join-Path $programFiles 'Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'),
        (Join-Path $programFilesX86 'Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe')
    ) -UiProcesses @('EpicGamesLauncher') -AlreadyRunning @('EpicGamesLauncher')

# Discord: Update.exe is the Squirrel stub that self-updates then launches
# Discord.exe; --process-start-args forwards --start-minimized to it.
Start-Launcher -Key 'Discord' -Label 'Discord' `
    -Arguments @('--processStart', 'Discord.exe', '--process-start-args', '--start-minimized') `
    -Paths @((Join-Path $env:LOCALAPPDATA 'Discord\Update.exe')) `
    -UiProcesses @('Discord') -AlreadyRunning @('Discord')

# Battle.net: no documented silent switch; minimize pass handles it.
Start-Launcher -Key 'Battlenet' -Label 'Battle.net' `
    -Paths @(
        (Join-Path $programFilesX86 'Battle.net\Battle.net Launcher.exe'),
        (Join-Path $programFiles 'Battle.net\Battle.net Launcher.exe')
    ) -UiProcesses @('Battle.net', 'Battle.net Launcher') -AlreadyRunning @('Battle.net')

if ($script:WatchPids.Count -eq 0) {
    # Nothing was actually started, so there is no window to chase - skip the
    # settle loop rather than idling for $SettleSec doing nothing.
    Write-Host '[launch] Nothing new to start.'
    exit ([int]($script:FailedCount -gt 0))
}

# Keep pushing windows down as they appear. Launchers paint their first
# window seconds after start, and some paint a second one after logging in.
$deadline = (Get-Date).AddSeconds($SettleSec)
$total = 0
while ((Get-Date) -lt $deadline) {
    $total += Minimize-WatchedWindows
    Start-Sleep -Milliseconds 500
}
if ($total -gt 0) {
    Write-Host "[launch] Sent $total launcher window(s) to the taskbar."
}
Write-Host '[launch] Launchers running in the background.'
if ($script:FailedCount -gt 0) {
    Write-Host "[launch] $script:FailedCount launcher(s) failed to start - see above."
    exit 1
}
exit 0
