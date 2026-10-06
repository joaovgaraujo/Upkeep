# Upkeep 1.8.0

A full run now takes the PC to Windows 11 26H2, and finishes sooner: the client lane no longer waits its turn behind the package managers.

## Windows version upgrade (26H2)

26H2 shares the 24H2/25H2 servicing branch, so it ships as an enablement package - a ~170 KB switch that flips already-staged binaries rather than a reinstall. That is cheap enough to belong in an update pass, but three things kept it out of reach of the ordinary Windows Update step, and `steps\Invoke-FeatureUpdate.ps1` handles each:

- **A feature-update deferral hides it entirely.** WinUtil's "security updates only" tweak writes `DeferFeatureUpdates` with a 365-day period, and while that is set Windows Update never offers 26H2. The step clears that (plus `PauseFeatureUpdates` and any `TargetReleaseVersion` pin) and saves every value it removes to `Documents\SystemUpdateLogs\FeatureUpdate_PolicyBackup_<date>_<time>.json`, in the format `steps\Restore-SetupRegistry.ps1` reads - so putting the tweak back is one command, printed in the log.
- **The enablement package enforces a floor build.** It refuses to install below KB5124010 (2026-09-22). Below that, quality updates are installed first; because a staged cumulative update does not take effect until the restart, the step stops there and says so rather than failing on an impossible install.
- **KB5121794 is not in the Microsoft Update Catalog.** Windows Update is asked first, so a machine the gradual rollout has reached takes the supported path. Only when it is not offered does the step fall back to the .msu on Microsoft's delivery CDN - and that package is rejected unless Authenticode reports a valid signature from Microsoft, since a .msu is applied with SYSTEM rights.

It never restarts the machine, matching the rest of the engine (`-IgnoreReboot`, `updates_auto_reboot = "no"`): a restart mid-run would kill every step queued behind it. The summary row says `ok - restart required`, and the dashboard's existing pending-restart banner takes it from there. A machine already on 26H2, or on a build the package does not apply to, reports `skipped` rather than an error.

The step is selected by default and is unticked as **Windows version upgrade (26H2)** in the sidebar and in the confirmation dialog, both of which carry an amber note that it changes the Windows version and needs a restart.

## Runs finish sooner

Store, JDownloader and Steam used to start only after the package managers and Windows servicing had finished, so their time - usually dominated by Steam's game downloads - was added to the total. They now start **before** the package managers and are joined just before the summary is printed:

```
before: winget -> choco -> topgrade -> Windows Update -> [store | jdownloader | steam]
now:    winget -> choco -> topgrade -> Windows Update -> 26H2
        [store | jdownloader | steam] running throughout, joined before the summary
```

Nothing in that lane calls winget, choco or msiexec - the Store step uses the MDM scan and AppX, JDownloader runs its own Java updater, Steam patches its own manifests - so the README's rule still holds: package managers stay sequential, and there is no installer contention. The feature update keeps its own slot after Windows Update, because an enablement package must not race installers and cannot apply while a restart is pending.

The lane is started with `start /b`, keeping it a child of the engine's `cmd`, so the dashboard's **Stop** still kills it. `steps\Wait-BackgroundStep.ps1` performs the join: it waits on the PID the worker records for itself, treats a missing PID file or an already-finished worker as nothing to wait for, refuses to wait on a PID the OS has recycled (the worker records its start time alongside the PID), and gives up with a `[timeout]` line instead of killing a worker whose own timeout handling owns that decision.

Progress reporting had to change with it. Phase matching only ever moves forward, so an early `[steam]` line would have jumped the bar to the last phase and frozen it there; the client lane now only owns a progress phase when it is the entire run.

## Apps that need a manual update are listed, not failed

A run on this PC on 2026-10-06 ended with `winget : error` and `topgrade : error`, and none of the five causes was a broken update. Each one was traced through the installer's own log:

- **Epic Games Launcher**, MSI exit 1603. Its LaunchCondition reads "Epic Games Launcher is currently running", and the engine starts Epic before the winget pass. The winget step now closes `EpicGamesLauncher` and `EpicWebHelper` before upgrading and starts the launcher again with `-silent`.
- **Git for Windows** through Chocolatey, exit 1. Setup's log shows "The following process(es) use Git for Windows: bash.exe ... Defaulting to Cancel for suppressed message box", so one open Git Bash failed topgrade's whole Chocolatey step. `steps\Protect-InUsePackages.ps1` now pins `git.install` for the run when anything from the Git folder is running, names those processes, and removes the pin after topgrade. A pin left by a killed run is removed at the start of the next one. Upkeep never kills the processes.
- **Zed**, "No applicable upgrade found". Zed installs per-user with Inno Setup, while its winget manifest declares a machine-wide installer. The winget step downloads the installer with `winget download` (manifest hash checked), requires a valid Authenticode signature, and runs it with `/CURRENTUSER` as the normal desktop user.
- **Microsoft Edge**, install technology changed. The old message told users to uninstall Edge with winget. Edge is now never upgraded through winget: the step asks EdgeUpdate for an on-demand install of the stable channel, which updates in place. On this PC the `MicrosoftEdgeUpdate*` scheduled tasks had been deleted, so Edge had stopped updating itself.
- **Sunshine**, install technology changed, from NSIS to WiX. This one is not automated, because the uninstall can take the configuration in `C:\Program Files\Sunshine\config` with it.

Whatever is still pending for one of these structural reasons goes to `Reports\manual-updates-<source>.json` instead of the error count. `steps\Show-ManualUpdates.ps1` prints the list, with the reason and the fix for each app, just before the summary block. It goes before the summary because the dashboard closes the engine 65 seconds after the summary appears. The winget step exits 3 in that case and the summary reads `winget : ok - some apps need a manual update`. These apps stay out of `winget-failed.json`, since retrying them changes nothing. Genuine installer failures are still errors.

## Claude Code and Codex CLI

topgrade's `node` step is disabled in the generated config, so npm-installed CLIs were never updated, and the native installs only update through their own `update` command. `steps\Update-AiClis.ps1` finds each install and updates it through the same channel:

| Install | Update |
|---|---|
| npm global (`@anthropic-ai/claude-code`, `@openai/codex`) | `npm install -g <package>@latest`, skipped when `npm view` reports the installed version is already the newest |
| Claude Code native (`~\.local\bin\claude.exe`) | `claude update` |
| Codex standalone (`%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`) | `codex update` |
| winget, Chocolatey, Scoop, Store | left to those steps |

The updates run as the normal desktop user, because all of these installs live in the user profile. `codex update` starts Windows PowerShell 5.1, and launched from a PowerShell 7 session it inherited PS7's `PSModulePath` and failed with "Get-FileHash is not recognized". The step resets the module path first. A failed update, for example npm hitting `EBUSY` while the CLI is running, is listed for a manual update with the command to run.

## Validation

- 75 Rust tests passed. `cargo fmt` and Clippy were not run locally - this machine's Rust install has no `rustfmt` or `cargo-clippy` component - so CI is the gate for those.
- All 150 PowerShell tests passed, including 9 new ones in `tests/FeatureUpdate.Tests.ps1`: the two "not applicable" exits, the dry run, prerequisite output streaming while the job is still running, a faulting prerequisite job, and the four join cases (no lane, a live worker, a recycled PID, and a worker that outlives the timeout). Three of those had depended on the test machine's real pending-restart flag and failed whenever a restart was pending. Tests that substitute the job bodies now ignore that flag, and a dry run reports a pending restart and continues. The manual-update changes add 13 tests: the winget scenarios for an installer-type change, Edge and a genuine failure, closing Epic, the end-of-run list, holding and releasing the Git pin, and the npm path of the CLI step.
- The upgrade step was exercised as a dry run on Windows 11 25H2 (26200.9457), where it correctly identified the 365-day feature-update deferral and the missing prerequisite cumulative update. The enablement package's download URL and Microsoft signature were verified separately; the apply itself has not been run on this machine yet, because the prerequisite cumulative update is not installed.

## Note on the 1.7.2 notes

`docs/RELEASE-1.7.2.md` records its validation as "Windows 11 26H2 (26300.9457)". The machine it was written on reports `DisplayVersion 25H2`, build `26200.9457` - 26H2 is build 26300, and the matching `.9457` revision suggests the build number was transcribed rather than read. Nothing in 1.7.2 depends on it; the version string in those notes is simply wrong.
