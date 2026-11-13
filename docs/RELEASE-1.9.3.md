# Upkeep 1.9.3

A download that never finishes no longer holds up the end of a run. RustDesk updates again, and the progress bar shows how far the run really is.

## A stuck download no longer holds up the run

Since 1.9.0 the winget step downloads every pending package ahead, four at a time, and installs each one as its download finishes. Two runs, on 2026-11-12 and 11-13, never finished the winget step. Each time one download never returned:

- On the 12th it was PowerShell 7.7. The second install lane waited the full 15 minutes for it before installing it anyway. After the last install, the step then waited on that download until the run was stopped 26 minutes later.
- On the 13th, 12 of 13 packages were installed in two and a half minutes. The last one was still waiting for its download when the run was stopped 6 minutes later.

Both times the stuck package shared a file with another download: GitHub Copilot CLI depends on PowerShell, so both download the same PowerShell package. Run side by side, one of them fails with `0x80070020` "The process cannot access the file because it is being used by another process". During those runs, one never returned at all.

Now:

- A download still running after 5 minutes is stopped, and winget downloads that package itself during the install. The log says when this happens.
- Once every package is installed, the step stops any download still running instead of waiting for it.

## RustDesk updates

winget has no RustDesk package, so winget couldn't match the installed copy and nothing updated it: 1.5.1 stayed installed while 1.5.3 was out. A new step in the client lane, next to G HUB, does it:

1. It reads RustDesk's latest release from GitHub and downloads the installer of the kind that is installed (`.exe` or `.msi`).
2. It checks the file against the SHA-256 GitHub publishes, and checks that the installer is signed by the same signer as the installed `RustDesk.exe`.
3. It installs silently and waits until Windows lists the new version.

The installer also adds and starts the RustDesk service and starts RustDesk. The step puts back how things were. A service that wasn't there before is removed, an existing service keeps its start type, new startup entries are removed, and RustDesk is closed if it wasn't running before.

Two cases are left alone:

- If someone is connected to the PC through RustDesk, it isn't updated, because that would end the session. It's listed at the end of the run instead.
- A RustDesk installed by Chocolatey is left to Chocolatey.

The summary has a new `RustDesk` line.

## A progress bar that follows the run

The bar used fixed weights per phase and eased toward the end of the current phase within about a minute, then sat there. It never read winget's package counter: those lines start with `[winget]`, and the parser expected `(i/n)` first. In a long winget phase it showed the same number for most of the run.

The bar is now elapsed time divided by elapsed time plus the time the run probably still needs:

- Each phase's length comes from the last five completed runs, read from the timestamps in `Upkeep_*.log`.
- The winget phase scales with the number of packages pending and shrinks as each one finishes.
- A phase that runs longer than usual slows the bar down instead of stopping it.
- The bar never moves backwards.

Under the bar, next to the phase, it shows the time left ("about 3 min left").

Replaying the last completed run on the development PC through the new model: 108 s into a 226 s run the bar showed 46%, against 48% of the time actually gone.

## Validation

- 188 PowerShell tests pass under Windows PowerShell 5.1. New tests cover: downloads that never finish, in both install lanes, with the step done well inside two minutes; and the RustDesk step on a fake install and release (not installed, installed by Chocolatey, already current, newer release, no matching installer).
- 83 Rust tests pass. New tests cover learning phase lengths from a log (including a run past midnight and a stopped run), the winget countdown, a phase running long, and skipped phases.
