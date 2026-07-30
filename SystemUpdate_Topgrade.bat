@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
rem ============================================================
rem  SystemUpdate_Topgrade.bat
rem  Self-elevating launcher that runs topgrade with config at
rem  %APPDATA%\topgrade.toml. Installs topgrade if missing.
rem  Pins live in the [pins] section and are managed from the GUI's Pins tab.
rem ============================================================

rem -- Interactive vs dashboard mode ----------------------------------------
rem    The GUI spawns us with stdin redirected to NUL. Both `pause` and
rem    `timeout` refuse to run without a console input handle and abort with
rem    "ERROR: Input redirection is not supported, exiting the process
rem    immediately." on STDERR -- which the dashboard pipes straight into its
rem    log, where it reads as a failure even though nothing went wrong.
rem    DASHBOARD_RUN=1 (set by the GUI) means "nobody is watching this
rem    window": skip every prompt and the closing countdown.
set "INTERACTIVE=1"
if "%DASHBOARD_RUN%"=="1" set "INTERACTIVE=0"

rem -- Self-elevate to administrator (UAC prompt) ---------------------------
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator elevation...
    powershell -NoProfile -Command "$p = Start-Process -FilePath '%~f0' -Verb RunAs -PassThru -ErrorAction Stop" 2>nul
    if errorlevel 1 (
        echo.
        echo Elevation was declined or failed. This script requires administrator
        echo rights to update system packages. Nothing was changed.
        if "%INTERACTIVE%"=="1" pause
        exit /b 1
    )
    exit /b
)

rem -- Single-instance guard --------------------------------------------------
rem    mkdir is atomic, so this can't race even if two elevated copies start
rem    at the same instant. Prevents a double-click plus a scheduled task
rem    from fighting over the same winget/choco/topgrade caches at once.
set "LOCKDIR=%TEMP%\SystemUpdate_Topgrade.lock"
rem    %TEMP% carries the account name, and Windows allows an apostrophe in
rem    it; escape for the single-quoted PowerShell literal below (see the
rem    TGCONF_PS note further down for the full explanation).
set "LOCKDIR_PS=%LOCKDIR:'=''%"
if exist "%LOCKDIR%" (
    rem Stale-lock recovery, two independent rules:
    rem  1. Created before the last boot. %TEMP% survives a restart but no
    rem     process does, so such a lock CANNOT belong to a live run. This is
    rem     the common case: kill the GUI (or lose power) mid-run and the bat
    rem     never reaches its rmdir, leaving a lock that outlives the reboot
    rem     and reports "already in progress" on a machine running nothing.
    rem  2. Older than 3 hours, for a run that died without a restart since.
    powershell -NoProfile -Command ^
      "$d = Get-Item '%LOCKDIR_PS%' -ErrorAction SilentlyContinue;" ^
      "if ($d) {" ^
      "  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime;" ^
      "  if ($d.CreationTime -lt $boot -or ((Get-Date) - $d.CreationTime).TotalHours -gt 3) {" ^
      "    Remove-Item '%LOCKDIR_PS%' -Recurse -Force } }"
)
mkdir "%LOCKDIR%" 2>nul
if errorlevel 1 (
    echo A System Update run is already in progress. Exiting.
    if "%INTERACTIVE%"=="1" pause
    exit /b 1
)

echo.
echo ========================================
echo   System Update via Topgrade
echo ========================================
echo.
for /f "delims=" %%I in ('powershell -NoProfile -Command "Get-Date -Format o"') do set "RUN_START=%%I"

rem -- Pre-flight: ensure winget is available -------------------------------
where winget >nul 2>&1
if %errorLevel% neq 0 (
    echo [setup] winget not found. Trying to register App Installer...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Get-AppxPackage Microsoft.DesktopAppInstaller | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $_.InstallLocation 'AppXManifest.xml') -ErrorAction SilentlyContinue }"
    where winget >nul 2>&1
    if %errorLevel% neq 0 (
        echo [setup] Downloading App Installer from Microsoft...
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
          "$ErrorActionPreference='Stop'; try { $o = Join-Path $env:TEMP 'AppInstaller.msixbundle'; Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $o; Add-AppxPackage $o; Write-Host '   App Installer installed.' } catch { Write-Host '   Could not auto-install winget:' $_.Exception.Message }"
        rem refresh PATH so winget is callable this session
        for /f "delims=" %%P in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"') do set "PATH=%%P"
    )
)
where winget >nul 2>&1 && (echo [setup] winget OK) || (echo [warn] winget still unavailable - winget steps will be skipped.)

rem -- Pre-flight: ensure Chocolatey is available ---------------------------
where choco >nul 2>&1
if %errorLevel% neq 0 (
    echo [setup] Chocolatey not found, installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    rem refresh PATH so choco is callable this session
    for /f "delims=" %%P in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"') do set "PATH=%%P"
)
where choco >nul 2>&1 && (echo [setup] Chocolatey OK) || (echo [warn] Chocolatey still unavailable - choco steps will be skipped.)

rem -- Quieten Chocolatey download progress (topgrade calls choco without
rem    --no-progress, which otherwise spams thousands of progress lines into
rem    the log). This is a one-time global choco setting.
where choco >nul 2>&1 && choco feature disable -n=showDownloadProgress >nul 2>&1

rem -- Ensure topgrade is installed -----------------------------------------
where topgrade >nul 2>&1
if %errorLevel% neq 0 (
    echo [setup] topgrade not found, installing via winget...
    winget install --id=topgrade-rs.topgrade -e --accept-source-agreements --accept-package-agreements --silent
    if %errorLevel% neq 0 (
        echo [setup] winget install failed, trying chocolatey...
        where choco >nul 2>&1
        if %errorLevel% neq 0 (
            echo [error] Neither winget nor choco available. Install topgrade manually.
            rmdir "%LOCKDIR%" 2>nul
            if "%INTERACTIVE%"=="1" pause
            exit /b 1
        )
        choco install topgrade -y --no-progress
    )
    rem refresh PATH so topgrade is callable in this session
    for /f "delims=" %%P in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"') do set "PATH=%%P"
)

rem -- Ensure PSWindowsUpdate is installed (topgrade uses it) ----------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (-not (Get-Module -ListAvailable PSWindowsUpdate)) { Install-PackageProvider NuGet -Force | Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Module PSWindowsUpdate -Force -Scope AllUsers }"

rem -- Apply pins (idempotent, ignores already-pinned errors) ---------------
rem    ONLY broken-updater workarounds ship pinned by default. A pin stops a
rem    package receiving updates INCLUDING SECURITY UPDATES, so shipping a
rem    preference pin as a default would silently hold back other people's
rem    software. Adobe Acrobat Reader used to be pinned here and no longer is:
rem    add it from the Pins tab if you want it, where the choice is yours and
rem    visible. The two below are cases where the updater itself is broken, so
rem    pinning changes nothing except removing a failure from every run.
rem
rem    NOTE for editors: the GUI's Pins tab rewrites this whole section as a
rem    flat list (see gui/src/pins.rs write_pins), so do NOT wrap these in an
rem    `if` gate -- the first save from the GUI would drop it and silently
rem    re-enable whatever the gate was protecting. Ship-or-don't-ship is the
rem    only reliable control here. These comments are also lost on first save.
echo [pins] Pinning packages in winget and chocolatey...
where winget >nul 2>&1 && (
    rem MiKTeX's winget installer pops a setup window every run and never
    rem actually bumps the tracked version. Pin it; MiKTeX updates its own
    rem packages via topgrade's miktex step. Unpin to update core manually:
    rem   winget pin remove --id MiKTeX.MiKTeX
    winget pin add --id MiKTeX.MiKTeX              --accept-source-agreements >nul 2>&1
    rem Heroic's winget upgrade fails with "install technology is different"
    rem and needs a manual uninstall+reinstall to fix - not worth automating
    rem for an infrequent game launcher update. Pinned so it's skipped cleanly.
    rem Unpin to update manually: winget pin remove --id HeroicGamesLauncher.HeroicGamesLauncher
    winget pin add --id HeroicGamesLauncher.HeroicGamesLauncher --accept-source-agreements >nul 2>&1
)

rem -- Prevent Discord from adding itself to Windows startup ----------------
rem    Discord re-adds its autostart entry every time it launches or
rem    self-updates, so this runs TWICE: once here, and again after the
rem    launcher step near the end (which is the run that actually sticks).
rem    See steps\Disable-DiscordAutostart.ps1 - it covers the machine-wide
rem    HKLM\WOW6432Node Squirrel entry too, not just the per-user one. That
rem    machine entry is why it kept coming back, and why Discord could open
rem    twice at logon.
echo [discord] Disabling Discord run-at-startup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Disable-DiscordAutostart.ps1"

rem -- Detect EA app BEFORE the run ----------------------------------------
rem    The EA app updater sometimes uninstalls the client entirely. Record
rem    whether it was installed so we can reinstall it afterwards if it
rem    vanishes during the update.
set "EA_LAUNCHER=%ProgramFiles%\Electronic Arts\EA Desktop\EA Desktop\EALauncher.exe"
set "EA_DESKTOP=%ProgramFiles%\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe"
set "EA_WAS_INSTALLED=0"
if exist "%EA_LAUNCHER%" set "EA_WAS_INSTALLED=1"
if exist "%EA_DESKTOP%" set "EA_WAS_INSTALLED=1"
if "%EA_WAS_INSTALLED%"=="1" (
    echo [ea] EA app detected - will verify it survives the update.
) else (
    echo [ea] EA app not installed - no reinstall guard needed.
)

rem -- Microsoft Store app updates ------------------------------------------
rem    Topgrade's winget msstore handling is unreliable, and a plain
rem    "winget upgrade --source msstore" often does nothing. The dependable
rem    path is steps\Update-StoreApps.ps1: it fires the MDM UpdateScanMethod
rem    AND drives per-app updates through the WinRT AppInstallManager, which
rem    gives a real progress/completion signal instead of fire-and-forget.
set "STORE_STATUS=skipped"
if not "%DASHBOARD_SKIP_STORE%"=="1" (
echo [store] Updating Microsoft Store apps...
set "STORE_STATUS=ok"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Update-StoreApps.ps1"
if "!errorLevel!"=="2" (set "STORE_STATUS=skipped") else if not "!errorLevel!"=="0" set "STORE_STATUS=error"
)

rem -- Write topgrade config (dedicated file, overwritten each run) ---------
rem    Used via --config so an existing %APPDATA%\topgrade.toml can't override
rem    it. App launching is done by THIS bat (below), not topgrade pre/post
rem    commands, to avoid nested pwsh/powershell variable-expansion bugs.
set "TGDIR=%LOCALAPPDATA%\SystemUpdate"
set "TGCONF=%TGDIR%\topgrade.toml"
rem    TGCONF/LOGFILE derive from %LOCALAPPDATA% and %USERPROFILE%, so they
rem    carry the account name -- and Windows allows an apostrophe in that.
rem    These paths get pasted into SINGLE-QUOTED PowerShell literals further
rem    down, where a bare ' ends the string and breaks the whole -Command
rem    block, so pre-double it here the way PowerShell expects. Use the _PS
rem    variants ONLY inside single quotes; the plain ones stay correct for
rem    batch redirection and "..."-quoted arguments.
set "TGCONF_PS=%TGCONF:'=''%"
if not exist "%TGDIR%" mkdir "%TGDIR%" >nul 2>&1
echo [setup] Writing topgrade config...
>"%TGCONF%" (
    echo # Topgrade config - generated by SystemUpdate_Topgrade.bat
    echo # Regenerated every run - edit the .bat, not this file.
    echo.
    echo [misc]
    echo assume_yes = true
    echo no_retry = true
    echo cleanup = true
    echo set_title = false
    echo skip_notify = true
    rem ollama is disabled: it "ollama pull"s every LOCAL model to refresh it,
    rem sequentially, with no way to filter which ones. On a machine with many
    rem multi-GB models this can run for a very long time and looks like a
    rem hang. Update ollama models manually when you want to: ollama pull <model>
    rem microsoft_store is disabled: we already trigger Store updates above
    rem via the reliable CIM UpdateScanMethod, so topgrade probing it too is
    rem redundant.
    echo disable = ["containers", "node", "pipx", "winget", "ollama", "microsoft_store"]
    echo.
    echo [windows]
    echo accept_all_updates = true
)
echo [setup] Config written to %TGCONF%

rem -- Logging --------------------------------------------------------------
set "LOGDIR=%USERPROFILE%\Documents\SystemUpdateLogs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

rem Keep only the most recent 20 logs so this folder doesn't grow forever.
powershell -NoProfile -Command ^
  "Get-ChildItem -Path '%LOGDIR%' -Filter 'Topgrade_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue"

for /f "delims=" %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%I"
set "LOGFILE=%LOGDIR%\Topgrade_%STAMP%.log"
rem See the TGCONF_PS note above: same escaping, same single-quote-only use.
set "LOGFILE_PS=%LOGFILE:'=''%"

echo.
echo [run] Starting topgrade. Log: %LOGFILE%
echo.

rem -- Launch game/download clients (they self-update) ----------------------
rem    Steam and JDownloader are no longer launched here - they have dedicated
rem    update steps below (steps\Update-SteamGames.ps1 needs Steam CLOSED to
rem    patch manifests, and steps\Update-JDownloader.ps1 needs JD closed for
rem    the bounded -update pass).
rem    They start minimized / to tray and are pushed back down if they pop a
rem    window anyway - see steps\Start-Launchers.ps1.
if not "%DASHBOARD_SKIP_APPS%"=="1" (
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Start-Launchers.ps1" -Only EA,Epic
rem There is no summary row for launchers, so surface a failure as a [warn]
rem line - the dashboard colours those amber - rather than dropping it.
if not "!errorLevel!"=="0" echo [warn] Some game clients could not be started - see the [launch] lines above.
)

rem -- JDownloader 2 self-update (bounded, headless) -------------------------
set "JD_STATUS=skipped"
if not "%DASHBOARD_SKIP_APPS%"=="1" (
echo [jdownloader] Updating JDownloader 2...
set "JD_STATUS=ok"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Update-JDownloader.ps1"
if "!errorLevel!"=="2" (set "JD_STATUS=skipped") else if not "!errorLevel!"=="0" set "JD_STATUS=error"
)

rem -- Winget upgrades (handled here, not topgrade, so we can pass
rem    --disable-interactivity for maximum unattended behavior). Honors the
rem    pins set above. --silent asks each installer to run quietly;
rem    a few installers (e.g. MiKTeX) still show their own UI regardless - pin
rem    those with: winget pin add --id <Id>
rem    steps\Update-WingetApps.ps1 wraps the upgrade with a before/after
rem    snapshot so packages that silently refuse to move are NAMED with the
rem    reason, instead of vanishing into the log while this step reports "ok".
rem    The usual reason is UPDATE_NOT_APPLICABLE (0x8A15002B) - the manifest's
rem    installer doesn't match how the app is installed here (user-scope
rem    install, or the app self-updates so winget's tracked version never
rem    moves). That is not a broken winget and not a transient failure.
set "WINGET_STATUS=skipped"
if not "%DASHBOARD_SKIP_APPS%"=="1" (
set "WINGET_STATUS=ok"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Update-WingetApps.ps1" -LogFile "%LOGFILE%"
if "!errorLevel!"=="2" (set "WINGET_STATUS=skipped") else if not "!errorLevel!"=="0" set "WINGET_STATUS=error"
)

rem -- Find packages winget lists as needing "explicit targeting" (this is
rem    separate from pins - it's how some publishers declare their manifest).
rem    We'll offer to update these individually at the very end of the run.
if not "%DASHBOARD_SKIP_APPS%"=="1" (
set "EXPLICIT_LIST=%TEMP%\sysupd_explicit_ids.txt"
del "!EXPLICIT_LIST!" 2>nul
powershell -NoProfile -Command ^
  "$raw = winget upgrade --include-unknown --accept-source-agreements 2>&1 | Out-String;" ^
  "$lines = $raw -split \"`r?`n\";" ^
  "$start = -1; for ($i=0;$i -lt $lines.Count;$i++){ if ($lines[$i] -match 'require explicit targeting'){$start=$i+1;break} };" ^
  "if ($start -ge 0 -and $lines[$start] -match 'Id') {" ^
  "  $header=$lines[$start]; $idPos=$header.IndexOf('Id'); $verPos=$header.IndexOf('Version');" ^
  "  for ($j=$start+2;$j -lt $lines.Count;$j++) {" ^
  "    $l=$lines[$j]; if ([string]::IsNullOrWhiteSpace($l)) { break }; if ($l -match '^\d+ package'){ break };" ^
  "    if ($l.Length -gt $verPos) { $id=$l.Substring($idPos,$verPos-$idPos).Trim(); if ($id) { $id | Out-File -FilePath '%TEMP%\sysupd_explicit_ids.txt' -Append -Encoding ascii } }" ^
  "  }" ^
  "}"
)

rem -- Run topgrade (with a watchdog timeout) -------------------------------
rem    No -k: that flag adds topgrade's interactive (R)eboot/(P)oweroff/
rem    (S)hell/(Q)uit prompt at the end, which would block the steps below
rem    (Windows Update, EA guard, app launches). The bat's own pause at the
rem    end keeps the window open instead.
rem    --config forces our settings regardless of any existing user config.
rem    TOPGRADE_TIMEOUT_MIN: if topgrade itself hangs on some step we didn't
rem    anticipate (slow download, stuck installer, etc.), kill it after this
rem    many minutes so the rest of the script (Windows Update, app launches)
rem    still runs instead of the whole thing being stuck forever.
rem    The wrapper ends with an explicit `exit $code` carrying topgrade's own
rem    exit status. Without it, %errorLevel% would be whatever the LAST
rem    statement set - previously `Remove-Item`, which reports failure when the
rem    raw files are already gone, painting a clean run as "exit code 1".
rem    NOTE: these two sets must stay OUTSIDE the if-block below. %VAR% inside
rem    a parenthesized block expands at parse time (before the set runs), which
rem    would turn WaitForExit(%TOPGRADE_TIMEOUT_MIN% * 60000) into a PowerShell
rem    parse error and silently skip topgrade entirely.
rem    Uses [Diagnostics.Process]::Start rather than Start-Process: in
rem    Windows PowerShell 5.1 a `Start-Process -PassThru` object WITHOUT
rem    -Wait never populates .ExitCode (verified - it comes back empty), so
rem    topgrade's real status was unobtainable and %errorLevel% ended up
rem    reflecting whatever the last statement did. Reading the two pipes with
rem    ReadToEndAsync also removes the .raw/.err temp files entirely.
rem    [char]34 builds the quotes around the config path without fighting
rem    batch's own quoting, so a path with spaces still works.
set "TOPGRADE_TIMEOUT_MIN=45"
if not "%DASHBOARD_SKIP_APPS%"=="1" (
powershell -NoProfile -Command ^
  "$psi = New-Object Diagnostics.ProcessStartInfo;" ^
  "$psi.FileName = 'topgrade';" ^
  "$psi.Arguments = '--config ' + [char]34 + '%TGCONF_PS%' + [char]34;" ^
  "$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true;" ^
  "$p = [Diagnostics.Process]::Start($psi);" ^
  "$so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync();" ^
  "$exited = $p.WaitForExit(%TOPGRADE_TIMEOUT_MIN% * 60000);" ^
  "if (-not $exited) { Write-Host ''; Write-Host ('[timeout] topgrade exceeded {0} minutes - killing it and moving on.' -f %TOPGRADE_TIMEOUT_MIN%); try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {}; try { $p.Kill() } catch {}; $p.WaitForExit(5000) | Out-Null };" ^
  "$code = if ($exited) { $p.ExitCode } else { 1 };" ^
  "foreach ($t in @($so, $se)) { if ($t.Wait(10000) -and $t.Result) { $t.Result | Write-Host; $t.Result | Out-File -FilePath '%LOGFILE_PS%' -Append -Encoding utf8 } };" ^
  "exit $code"
)

if not "%DASHBOARD_SKIP_APPS%"=="1" (set "RC=!errorLevel!") else (set "RC=0")

rem -- Windows Update (explicit, with a watchdog timeout) -------------------
rem    topgrade folds Windows Update into its "system" step, which it
rem    silently SKIPS on this machine. So we run it directly via
rem    PSWindowsUpdate (installed earlier). This is the reliable path.
rem    Same watchdog pattern as topgrade above: a stuck scan/download
rem    shouldn't block the rest of the script (EA guard, app launches)
rem    forever. Runs as a background job so Stop-Job reliably tears down
rem    its own worker process.
set "WU_STATUS=skipped"
rem    WU_TIMEOUT_MIN must be set OUTSIDE the block - see the topgrade note above.
set "WU_TIMEOUT_MIN=40"
if not "%DASHBOARD_SKIP_WINUPDATE%"=="1" (
echo.
echo [winupdate] Installing Windows updates (this can take a while^)...
set "WU_STATUS=ok"
rem    -ExecutionPolicy Bypass is REQUIRED, not decorative: this machine has
rem    no execution policy set in any scope, which means Restricted, and the
rem    job below does Import-Module PSWindowsUpdate -- loading a .psm1 from
rem    disk, which Restricted forbids. Without it the job fails every single
rem    run with "PSWindowsUpdate.psm1 cannot be loaded because running
rem    scripts is disabled on this system", so Windows Update reported error
rem    even when Windows had nothing to install. The flag is inherited by the
rem    Start-Job child process, which is where the import actually happens.
rem    Note the install at the top of this script already passes Bypass --
rem    that is why the module installs fine but never loads.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$job = Start-Job -ScriptBlock { Import-Module PSWindowsUpdate -ErrorAction Stop; Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose 2>&1 | Out-String };" ^
  "$done = Wait-Job $job -Timeout (%WU_TIMEOUT_MIN% * 60);" ^
  "$code = 0;" ^
  "if (-not $done) { Write-Host ('[timeout] Windows Update exceeded {0} minutes - moving on.' -f %WU_TIMEOUT_MIN%); $code = 1 } else { Receive-Job $job -ErrorAction SilentlyContinue | Write-Host; if ($job.State -eq 'Failed') { $code = 1; foreach ($cj in $job.ChildJobs) { foreach ($e in $cj.Error) { Write-Host ('[error] ' + $e.Exception.Message) }; if ($cj.JobStateInfo.Reason) { Write-Host ('[error] ' + $cj.JobStateInfo.Reason.Message) } }; Write-Host '[warn] Windows Update job failed - see the [error] lines above.' } };" ^
  "Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue;" ^
  "exit $code"
if "!errorLevel!"=="2" (set "WU_STATUS=skipped") else if not "!errorLevel!"=="0" set "WU_STATUS=error"
)

rem -- EA app guard: reinstall if the update removed it ---------------------
rem    Each check is its own line so %EA_STILL% expands correctly without
rem    needing delayed expansion.
set "EA_STATUS=n/a"
if "%EA_WAS_INSTALLED%"=="1" set "EA_STILL=0"
if "%EA_WAS_INSTALLED%"=="1" if exist "%EA_LAUNCHER%" set "EA_STILL=1"
if "%EA_WAS_INSTALLED%"=="1" if exist "%EA_DESKTOP%"  set "EA_STILL=1"
if "%EA_WAS_INSTALLED%"=="1" if "%EA_STILL%"=="1" echo [ea] EA app still present after update. OK.
if "%EA_WAS_INSTALLED%"=="1" if "%EA_STILL%"=="1" set "EA_STATUS=ok"
if "%EA_WAS_INSTALLED%"=="1" if "%EA_STILL%"=="0" (
    echo.
    echo [ea] EA app was removed during the update - reinstalling...
    winget install --id ElectronicArts.EADesktop -e --accept-source-agreements --accept-package-agreements --silent
    if errorlevel 1 (
        echo [ea] Automatic reinstall failed. Get it from https://www.ea.com/ea-app
        set "EA_STATUS=reinstall failed"
    ) else (
        echo [ea] EA app reinstalled.
        set "EA_STATUS=reinstalled"
    )
)

rem -- Steam game updates (unattended) ---------------------------------------
rem    Closes Steam, flags every installed game for an update check, relaunches
rem    steam.exe -silent and waits (registry Updating flags + downloading dir,
rem    debounced). If the time budget runs out, downloads simply continue in
rem    the background - nothing is killed. Skip with DASHBOARD_SKIP_STEAM=1.
set "STEAM_TIMEOUT_MIN=60"
set "STEAM_STATUS=skipped"
if not "%DASHBOARD_SKIP_STEAM%"=="1" (
echo [steam] Updating Steam games...
set "STEAM_STATUS=ok"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Update-SteamGames.ps1" -TimeoutMin %STEAM_TIMEOUT_MIN%
if "!errorLevel!"=="2" (set "STEAM_STATUS=skipped") else if not "!errorLevel!"=="0" set "STEAM_STATUS=error"
)

rem -- Launch Discord and Battle.net (after updates) ------------------------
rem    Steam is deliberately absent here: the Steam step above already
rem    relaunched it with -silent after patching its manifests.
if not "%DASHBOARD_SKIP_APPS%"=="1" (
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Start-Launchers.ps1" -Only Discord,Battlenet
if not "!errorLevel!"=="0" echo [warn] Some chat clients could not be started - see the [launch] lines above.
)

rem -- Re-disable Discord autostart (AFTER it was launched) -----------------
rem    Launching Discord makes it put its Run entry back, so the pass at the
rem    top of this script is always undone by the launch above. This is the
rem    one that sticks - do not remove it or reorder it before the launch.
if not "%DASHBOARD_SKIP_APPS%"=="1" (
echo [discord] Re-checking Discord run-at-startup after launch...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steps\Disable-DiscordAutostart.ps1"
)

rem -- Summary --------------------------------------------------------------
if "%DASHBOARD_SKIP_APPS%"=="1" (
    set "TOPGRADE_STATUS=skipped"
) else (
    rem topgrade exits nonzero if ANY of its ~30 steps failed, and a single
    rem flaky one (a pnpm PATH warning, a transient registry fetch) is not a
    rem failed update run. Report it honestly but keep it in the "ok" family
    rem so the dashboard doesn't paint the whole category red - the per-step
    rem detail is in the log either way.
    if !RC! equ 0 (set "TOPGRADE_STATUS=ok") else (set "TOPGRADE_STATUS=ok - some steps failed, see log (exit !RC!^)")
)
for /f "delims=" %%I in ('powershell -NoProfile -Command "$s=Get-Date '%RUN_START%'; ((Get-Date)-$s).ToString('hh\:mm\:ss')"') do set "RUN_DURATION=%%I"

echo.
echo ========================================
echo   Summary  (duration: %RUN_DURATION%)
echo ----------------------------------------
echo   winget          : %WINGET_STATUS%
echo   topgrade        : %TOPGRADE_STATUS%
echo   Windows Update  : %WU_STATUS%
echo   Store           : %STORE_STATUS%
echo   Steam games     : %STEAM_STATUS%
echo   JDownloader     : %JD_STATUS%
echo   EA app          : %EA_STATUS%
echo ----------------------------------------
echo   Log: %LOGFILE%
echo ========================================

rem -- Offer to update packages that need explicit targeting ---------------
rem    These are NOT pinned/excluded on purpose - winget's manifest for them
rem    just requires --id targeting instead of --all.
if exist "%EXPLICIT_LIST%" (
    echo.
    echo ----------------------------------------
    echo   The following packages need explicit targeting to update:
    for /f "usebackq delims=" %%N in ("%EXPLICIT_LIST%") do echo     - %%N
    echo ----------------------------------------
    rem 20s timeout, defaults to No, so an unattended run doesn't block here.
    rem    Under the dashboard there is no console input handle, and `choice`
    rem    reacts to that the same way `timeout` does - it prints "ERROR: Input
    rem    redirection is not supported" to stderr and exits immediately. Skip
    rem    the prompt entirely there and take the same default it would (No).
    if "%INTERACTIVE%"=="0" (
        echo   Skipping the prompt - run the .bat directly to update these.
        goto :skip_explicit
    )
    choice /C YN /N /T 20 /D N /M "Update these now? (Y/N): "
    if errorlevel 2 goto :skip_explicit
    if errorlevel 1 (
        for /f "usebackq delims=" %%N in ("%EXPLICIT_LIST%") do (
            echo.
            if "%%N"=="Anaconda.Anaconda3" (
                call :update_conda "Anaconda3" "%LOCALAPPDATA%\anaconda3\condabin\conda.bat" "%USERPROFILE%\anaconda3\condabin\conda.bat"
            ) else if "%%N"=="Anaconda.Miniconda3" (
                call :update_conda "Miniconda3" "%USERPROFILE%\miniconda3\condabin\conda.bat" "%LOCALAPPDATA%\miniconda3\condabin\conda.bat"
            ) else (
                echo [explicit] Updating %%N ...
                winget upgrade --id "%%N" --silent --accept-source-agreements --accept-package-agreements
                if errorlevel 1 echo [explicit] %%N could not be updated via winget ^(publisher restriction or install-technology change^).
            )
        )
    )
    :skip_explicit
    del "%EXPLICIT_LIST%" 2>nul
)
goto :after_conda_fn

rem -- Anaconda/Miniconda: winget refuses to upgrade these packages
rem    ("cannot be upgraded using WinGet. Please use the method provided
rem    by the publisher"). The publisher's own method is:
rem      conda update -n base -c defaults conda
rem    Tries each candidate condabin path until one exists.
:update_conda
setlocal
set "CONDA_LABEL=%~1"
set "CONDA_BAT="
if exist "%~2" set "CONDA_BAT=%~2"
if not defined CONDA_BAT if exist "%~3" set "CONDA_BAT=%~3"
if not defined CONDA_BAT (
    echo [explicit] %CONDA_LABEL%: conda.bat not found in expected locations, skipping.
    endlocal & goto :eof
)
echo [explicit] Updating %CONDA_LABEL% via conda ^(publisher method^)...
call "%CONDA_BAT%" update -n base -c defaults conda -y
if errorlevel 1 (
    echo [explicit] %CONDA_LABEL% conda update reported an error - check output above.
) else (
    echo [explicit] %CONDA_LABEL% conda update finished.
)
endlocal & goto :eof
:after_conda_fn

rem -- Completion toast notification -----------------------------------------
rem    Lets you know the run is done without needing to watch the window.
rem    Skipped under the dashboard: the GUI sends its own toast from the
rem    parsed summary, so firing this one too produced TWO notifications that
rem    could disagree - this one used an exact "ok" match, so it cried
rem    "finished with issues" whenever topgrade was merely skipped.
rem    Any status in the "ok" family (including "ok - some steps failed")
rem    counts as a clean finish here, matching the GUI's own rule.
set "TOAST_TITLE=System Update finished with issues"
if "%TOPGRADE_STATUS%"=="ok" set "TOAST_TITLE=System Update finished"
if "%TOPGRADE_STATUS%"=="skipped" set "TOAST_TITLE=System Update finished"
if "!TOPGRADE_STATUS:~0,3!"=="ok " set "TOAST_TITLE=System Update finished"
if "%INTERACTIVE%"=="1" powershell -NoProfile -Command ^
  "try {" ^
  "  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;" ^
  "  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null;" ^
  "  $body = 'winget: %WINGET_STATUS%  |  topgrade: %TOPGRADE_STATUS%  |  WU: %WU_STATUS%  |  Store: %STORE_STATUS%  |  Steam: %STEAM_STATUS%  |  JD: %JD_STATUS%  |  EA: %EA_STATUS%';" ^
  "  $xml = [Windows.Data.Xml.Dom.XmlDocument]::new();" ^
  "  $xml.LoadXml(('<toast><visual><binding template=\"ToastGeneric\"><text>{0}</text><text>{1}</text></binding></visual></toast>' -f '%TOAST_TITLE%', $body));" ^
  "  $toast = [Windows.UI.Notifications.ToastNotification]::new($xml);" ^
  "  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('SystemUpdateTopgrade').Show($toast);" ^
  "} catch {}"

rem Release the single-instance lock BEFORE the closing countdown: the GUI
rem watchdog kills this process during the countdown, and a kill after this
rem line must not leave a stale lock that blocks the next run for 3 hours.
rmdir "%LOCKDIR%" 2>nul
rem The countdown only makes sense for a double-clicked run. Under the
rem dashboard, exit straight away: `timeout` can't run without a console
rem input handle, and exiting cleanly beats being killed by the watchdog.
if "%INTERACTIVE%"=="1" (
    echo.
    echo This window will close in 60 seconds (press a key to close now^)...
    timeout /t 60 >nul
)
rem Reaching here means every phase ran and the summary was printed, so the
rem ENGINE succeeded even if an individual step didn't. Per-step outcomes are
rem already in the summary block the dashboard parses; hard failures (no
rem winget/choco, lock held, elevation declined) exited nonzero much earlier.
rem Do NOT change this back to `exit /b %RC%`: RC is topgrade's status, and
rem one flaky package would mark the whole run failed.
exit /b 0

rem ============================================================
rem  README - notes for future you
rem ============================================================
rem
rem  Excluding a package is done with package manager pins, not regex. Nothing
rem  security-relevant ships pinned; manage your own from the GUI's Pins tab or:
rem    winget pin list
rem    winget pin add --id Adobe.Acrobat.Reader.64-bit
rem    winget pin remove --id Adobe.Acrobat.Reader.64-bit
rem    choco pin list
rem    choco pin add -n=adobereader
rem
rem  Edit which steps run:
rem    notepad %LOCALAPPDATA%\SystemUpdate\topgrade.toml
rem
rem  Useful one-off flags:
rem    topgrade --dry-run             show plan, do nothing
rem    topgrade --only winget         run a single step
rem    topgrade --disable windows_update
rem    topgrade -y -k                 yes-to-all, keep window open
rem
rem  Remote home lab updates - add to topgrade.toml:
rem    [misc]
rem    remote_topgrades = ["user@host1.lan","user@host2.lan"]
rem    (requires topgrade installed on each remote)
rem
rem  EA app guard:
rem    The EA app updater occasionally uninstalls the client. This script
rem    records whether it was installed before the run and reinstalls it
rem    (winget id ElectronicArts.EADesktop) if it disappears.
rem
rem  Microsoft Store apps:
rem    Triggered via the MDM UpdateScanMethod (reliable) plus a best-effort
rem    "winget upgrade --source msstore". Store apps finish updating in the
rem    background, so they may not all be done by the time this window closes.
rem    Force a check anytime: open Store > Library > Get updates.
rem
rem ============================================================
