# Upkeep 1.7.2

Update runs now show progress while they run instead of after each step finishes, and every run leaves a complete log even if it is stopped. Previously the WinGet pass, topgrade, Windows Update and the Store/Steam/JDownloader workers all collected their output and printed it only when they ended. A single slow installer (Rust's MSI took 19 minutes) left the dashboard silent long enough to look hung. Closing the window then killed the run, and the log file was never written.

- **Live session log.** The dashboard writes every line it receives, timestamped and flushed, to `Documents\SystemUpdateLogs\Upkeep_<date>_<time>.log`. The path is shown at the start of the run. Stops and exit codes are recorded, and the newest 20 logs are kept.
- **WinGet** prints `(n/N) Id old -> new...` before each package, and its time and exit code after. Output is appended to the log per package.
- **topgrade, Windows Update and the client workers** stream their output line by line. After 5 minutes of silence they print a `still running (N min elapsed)` heartbeat, and each step reports how long it took. topgrade and Windows Update moved into `steps\Invoke-Topgrade.ps1` and `steps\Invoke-WindowsUpdate.ps1`.
- **Closing the window during a run now asks first.** It explains that closing stops the update and that long installers can be silent for 10-20 minutes.
- **Log writes no longer abort a step.** If anything had the log open at the wrong moment, the "file in use" error used to fail all client workers with exit 1.

WinGet failures are explained better:

- A portable package that WinGet lists as upgradable but cannot match for upgrade is now reinstalled with `install --force` (seen with `yt-dlp.FFmpeg`).
- An install-technology mismatch (`0x8A15008E`, e.g. draw.io dropping its MSI) is now detected by exit code, not English text. The message includes the exact reinstall command.

Fixes from a full tool audit on Windows 11 26H2 (build 26300):

- **New PC / Drivers:** a tool path in `settings.json` that points into another Windows account's profile made PowerShell 5.1's `Test-Path` throw "Access is denied" and failed the whole Drivers phase. Such paths are now treated as unset, in both the scripts and the GUI's settings autodiscovery, so SDIO is found in the current profile.
- **Clean NVIDIA driver** now checks for an NVIDIA GPU before downloading about 700 MB.
- **USB4 repair** parses `pnputil` by value instead of English labels, so it works on localized Windows. It refuses to report a fix when it found nothing to remove.
- **Steam** app manifests are read and written as UTF-8 without a BOM. Previously Windows PowerShell 5.1 read them as ANSI, mangling non-ASCII game names, and wrote a BOM.

Validation on Windows 11 26H2 (26300.9457):

- 75 Rust tests passed, one network test intentionally ignored. Formatting and Clippy with warnings denied passed.
- All 128 PowerShell tests passed. The 6 new streaming tests check the log while the step is still running, and cover the timeout kill, launch failures and failed Windows Update jobs.
- New PC and Optimize dry runs passed on every phase. All 30 WinUtil tweak IDs exist in WinUtil 26.09.29.
- Every Tools page action was audited read-only. Startup apps, services, tasks, reports, app presets, display utilities, the update inventory, WSL and package manager setup, the self-update check and pending-reboot detection all work on 26H2.
