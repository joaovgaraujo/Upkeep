# Upkeep 1.9.9

A redesigned dashboard, a catalog of 262 apps, and winget as the single owner of the apps it tracks.

## A calmer dashboard

- One header bar holds the name, the page tabs and two icons: settings (theme, language, size) and About. The tabs are plain text, and the open one is underlined. The emoji are gone from the tab names.
- Green now marks the main button and success only. Ticked apps, options and tabs no longer turn green, and amber is kept for options with a real risk, such as the 26H2 restart.
- Page titles, section headings and labels use one type scale in Segoe UI, Windows' own font, with semibold for headings.
- The Update page opens with **Check for updates** beside a short explanation. Each source of updates (Windows Update, 26H2, Store, Steam, developer tools) is a row with a line saying what it covers.
- Install apps has a search box that matches name, description and winget ID, and shows how many apps are selected. The pack that was called "Everything" holds 56 of the 262 apps, so it is now called "Broad set".
- Startup & Services uses on/off switches with the state written next to them. Turned-off items are dimmed instead of struck through, and "your choice" advice is no longer amber.
- With the theme set to System, Upkeep reads the Windows light/dark setting itself and follows it while open. Before, a PC set to dark could still open Upkeep in light.
- The 26H2 option is hidden, and not ticked, on a PC already on build 26300 or later.

## winget owns what it tracks

- Before topgrade runs, Chocolatey's copy of every app winget tracks on the PC is pinned for that run, not only the ones winget updated earlier. An app winget failed on, or listed for a manual update, in the same run is still left to Chocolatey.
- topgrade's codex step is always off (Codex is updated by Upkeep's AI CLI step). Its self_update, tailscale, wsl_update, antigravity_cli and uv steps are turned off when winget tracks that app; uv tools are then upgraded directly.
- A package whose first attempt said it needs the normal user goes straight to the unelevated retry.

## winget is found when its folder is missing from PATH

On a PC whose saved user PATH had lost the WindowsApps folder, the elevated run found no winget, skipped every winget step and tried to reinstall App Installer and topgrade through Chocolatey. The launcher now adds the folder for the run when winget.exe is there, and the normal-user retry does the same.

## Prefetch downloads

A prefetch download is stopped after 5 minutes without growth or 30 minutes in total. Sizes are read from each file, because winget's partial file reads 0 bytes in a directory listing.

## App catalog and new-PC setup

- apps.json gains the 163 apps from winutil 26.11.13 that it did not have, plus Antigravity IDE and Antigravity CLI: 97 apps become 262, with English and Portuguese descriptions. The developer preset now installs Claude Code.
- New-PC setup runs a pinned copy of winutil from vendor/winutil, checked against its SHA-256, instead of downloading it at run time.
- Setup reports the state of Smart App Control and lists what it blocked during the run. The New PC page has an option, off by default, to turn it off before drivers and apps.

## For testing and screenshots

`UPKEEP_CAPTURE=<folder>` opens each page in turn, saves a screenshot and closes. `UPKEEP_CAPTURE_THEME=light|dark` picks the theme without saving it.

## Validation

- 86 Rust tests pass, including the layout checks at small window sizes, high zoom and both languages.
- 287 PowerShell tests pass under Windows PowerShell 5.1.
- Every page was captured in light and dark from the full build on the development PC and checked by eye.
