# Upkeep 1.9.1

A small fix from the first 1.9.0 run on the test laptop, plus two test fixes.

## Skipped skills no longer show as an error

When Windows PowerShell can't start for your normal user, which a dead network drive causes, 1.9.0 skips the normal-user steps after a 20-second check. The skills step still reported that as **error** in the summary, although it had attempted nothing. It now says **skipped**, and the log keeps the reason.

## Tests

- The first 1.9.0 release build failed on a timing test: it waited for a "still running" line that never came. On a slow machine the step could read the fake program's first line several seconds late, and the heartbeat counts from that read, so a 4-second silence could leave less than the 2-second heartbeat. The silences in the three streaming tests are now 10 seconds.
- A new test runs the script that the SSH relay's scheduled task uses, against an engine in a folder whose path has spaces, like `C:\Program Files\Upkeep`. It checks that the engine's output and exit code come back. `Invoke-InDesktop.ps1` has a `-WriteRunnerOnly` switch for this: it writes that script and stops without registering a task.

## Validation

- 179 PowerShell tests pass under Windows PowerShell 5.1.
- 1.9.0 ran on the test laptop over SSH with the engine itself taking 2 min 16 s. There was almost nothing to update, so that run doesn't measure the download-ahead. On that PC, any Windows PowerShell started in the SSH session first waits about 9 minutes on network drives whose server doesn't respond, before Upkeep's own code runs. Disconnecting or fixing those drives removes the wait. Upkeep can't skip it.
