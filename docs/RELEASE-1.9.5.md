# Upkeep 1.9.5

The Startup & Services page shows when every app's scheduled task runs. It can turn off everything marked "Safe to turn off" in one go, and what you turn off there stays off after app updates.

## Everything an app scheduled, and when it runs

The Scheduled tasks tab used to list only tasks that run at boot or sign-in. A task that an app scheduled on a timer had no column saying so. On one PC, a task reopened a monitoring app every 11 hours, and the tab showed it only as a sign-in task.

The tab now lists every task an app scheduled for itself, whatever starts it, plus Windows' own tasks that run at boot or sign-in. A new **When** column reads, for example, "At sign-in; Every 11 h", "Daily at 10:16", "Every 5 min" or "On lock/unlock".

## Turn off what's safe in one go

The Startup and Scheduled tasks tabs each have a **Turn off N safe-to-turn-off** button. These are the items the built-in advice marks "Safe to turn off": updaters, telemetry and preloaders that nothing needs at sign-in. It shows the list first and turns them off only when you confirm. Each item can be turned back on from its own switch.

The advice now covers AnyDesk, NordVPN, NetBird, SQL Server Browser, GIGABYTE EasyTune, usbipd, Microsoft's SoftLanding tips task and Firefox's background update and autostart entries.

## What you turn off stays off

App installers turn their own startup items back on. On 2026-11-13, a winget update of Tailscale set its service back to Automatic and re-created its Startup-folder shortcut. The same day, the RustDesk 1.5.3 installer added a "RustDesk Tray" shortcut to the all-users Startup folder.

Every change made on the Startup & Services page is now recorded in `%LOCALAPPDATA%\Upkeep\startup-choices.json`:

- startup apps turned off;
- scheduled tasks disabled;
- services set to Manual or Disabled.

After each update run, the engine checks those choices and switches off again whatever an update switched back on. The log says what it put back. Turning an item back on removes it from the list. An item whose app was uninstalled is skipped and kept in the list, in case the app comes back. Hovering the switch of an item turned off this way says that Upkeep keeps it off.

## RustDesk's startup shortcut

The RustDesk step (1.9.3) removed the service the installer added and any new Run-key entry. It didn't check the Startup folders, so RustDesk started at the next sign-in. It now also removes Startup-folder shortcuts the installer added.

## Validation

- 194 PowerShell tests pass under Windows PowerShell 5.1. New tests cover the engine step: no choices recorded; a startup item an update turned back on (turned off again); choices still in place (left alone); missing tasks and services (skipped); and a choices file written with a BOM.
- 86 Rust tests pass. New tests cover recording and forgetting choices and the file round trip, reading task triggers, and the "When" wording in English and Portuguese.
- Run against a real PC's scheduled tasks, the new query listed 77 tasks with their triggers.
