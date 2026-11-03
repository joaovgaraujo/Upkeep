# Upkeep 1.8.5

Shorter Store waits, and Store results that match what was installed. Both come from the two runs on 2026-11-03, the first of which took 21 minutes.

## The Store waits for all its updates at once

The Store step used to wait up to 300 seconds for each queued app, one after the other. When the queue stalls, every app in it runs out its full five minutes in turn. On 2026-10-28 five apps did that, the Store lane took 25 minutes, and it was the last thing the run waited for. On 2026-11-03 the queue sat behind Xbox Game Bar, whose update had not installed since August, and the lane took 19 minutes.

`steps\Update-StoreApps.ps1` now polls every queued app in one loop. It stops when they are all done, when none of them has changed state for 3 minutes (`-IdleStopSec`), or after 10 minutes (`-WaitMin`). Whatever is left stays queued in the Store, which keeps working on it after the run ends.

## "Updated" means the installed version changed

The 2026-11-03 run reported `updated: 8`. Checking the installed packages afterwards, five of the eight were still on the old version: WhatsApp, the Store itself, GamingApp, RawImageExtension and WinAppRuntime. The Store's queue showed them all at `Pending 0%`, with WhatsApp at `Paused`. The old check counted any app that reported 100% as installed, and the Store also reports 100% on an update it has cancelled (Photos returned `Canceled 100%`, `E_ABORT`).

The step now records each package's installed version before it starts and compares after the wait. Only a version that moved counts as updated. Every other app is reported with a reason:

- open, with the process holding it (`WhatsApp.Root.exe`), and listed under "Needs a manual update";
- cancelled by the Store itself, which retries it on its own;
- still queued in the Store.

A Store cancel no longer turns the Store row red. A real `Error` state still does.

## Installers that change nothing are not run again

Logitech G HUB's installer returns 0 and the installed version stays at 2026.4.919028. 1.8.4 put it on the manual-update list, but still ran the installer twice per run, once in the main pass and once more in the re-check. In the 10:39 run on 2026-11-03 the first of those took 183 seconds.

Two changes in `steps\Update-WingetApps.ps1`:

- The re-check no longer runs an installer that already returned success in the first pass. It goes straight to the version check.
- An app whose installer reported success without moving the version is saved to `Reports\winget-noop-installs.json`, together with the version winget offered. While winget still offers that same version, later runs list the app for a manual update without starting its installer. A newer version clears the entry and the installer runs again.

## Validation

- The PowerShell test suite passes, with the step scripts running under Windows PowerShell 5.1. Two tests are new: the no-op record is written for an installer that reports success without moving the version, and a recorded app is not installed again for the same version.
- The new Store step ran on the PC from these logs. It named WhatsApp as open (`WhatsApp.Root.exe`), reported the queued Microsoft.6365217CE6EB4 update as still queued instead of updated, and stopped after the idle limit rather than waiting five minutes per app.
