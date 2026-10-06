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

## Validation

- 75 Rust tests passed. `cargo fmt` and Clippy were not run locally - this machine's Rust install has no `rustfmt` or `cargo-clippy` component - so CI is the gate for those.
- All 137 PowerShell tests passed, including 9 new ones in `tests/FeatureUpdate.Tests.ps1`: the two "not applicable" exits, the dry run, prerequisite output streaming while the job is still running, a faulting prerequisite job, and the four join cases (no lane, a live worker, a recycled PID, and a worker that outlives the timeout).
- The upgrade step was exercised as a dry run on Windows 11 25H2 (26200.9457), where it correctly identified the 365-day feature-update deferral and the missing prerequisite cumulative update. The enablement package's download URL and Microsoft signature were verified separately; the apply itself has not been run on this machine yet, because the prerequisite cumulative update is not installed.

## Note on the 1.7.2 notes

`docs/RELEASE-1.7.2.md` records its validation as "Windows 11 26H2 (26300.9457)". The machine it was written on reports `DisplayVersion 25H2`, build `26200.9457` - 26H2 is build 26300, and the matching `.9457` revision suggests the build number was transcribed rather than read. Nothing in 1.7.2 depends on it; the version string in those notes is simply wrong.
