# Upkeep 1.4.1

Local release based on GitHub v1.4.0 (`3c1a3cf`), retaining the existing
local improvements and unelevated winget recovery.

- Block unattended EA upgrades in winget and Chocolatey after a confirmed
  installer-initiated restart; leave EA launch and repair to the user.
- Explicitly disable Topgrade automatic reboot and duplicate Windows
  servicing. Windows Update retains `-IgnoreReboot`.
- Run Store, Steam and JDownloader updates concurrently after package
  managers and Windows servicing, with bounded workers and recorded results.
- Report Topgrade failures, winget inventory/installer failures and
  unresolved upgrades accurately.
- Align the progress display with concurrent client updates.
- Retain v1.4.0's static CRT and graphics renderer fallback.

Packages: `Upkeep-Setup-1.4.1.exe` and `Upkeep-Portable-1.4.1.zip`.
The version also appears in the GUI, executable metadata and installer.
This build does not override independent Windows restart schedules or
guarantee the behavior of every third-party installer.
