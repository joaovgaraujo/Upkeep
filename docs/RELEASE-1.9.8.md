# Upkeep 1.9.8

Full runs are shorter, and a second download, `Upkeep-NoAdmin.zip`, updates what your account can update without ever showing a UAC prompt.

## Chocolatey skips what winget already updated

An app installed by both winget and Chocolatey was installed twice per run. In a run on 2026-11-23, winget updated calibre, Wireshark, AutoHotkey, gh, Rufus and FFmpeg, and a few minutes later Chocolatey ran each of their installers again, about a minute and a half in all. Chocolatey's record of an app doesn't change when winget updates it, so it always sees an update waiting.

The winget step now records every package it has updated in `%LOCALAPPDATA%\Upkeep\winget-owned.json`. Before topgrade runs, the matching Chocolatey packages are pinned for that run only and unpinned afterwards, the same way Git is held back while it's in use. If winget failed on an app, or listed it for a manual update, in the same run, Chocolatey still gets its turn. Set `UPKEEP_CHOCO_DUPLICATES=1` to turn this off.

## Quick topgrade steps run alongside winget again

Since 1.8.9, rustup, pip, Julia, MiKTeX, the gh extensions, Claude Code plugins and Tailscale were meant to run while winget installs. The winget step skipped them whenever a list of selected apps was passed, and **Review and update** always passes one, so from the dashboard they ran after winget every time. They now overlap winget there too.

## topgrade updating itself no longer fails winget

topgrade's Self update step replaces its own exe, so winget then finds the portable package "modified" and refuses to upgrade it (0x8A150057). The retry without administrator rights now adds `--force` in that case, as the elevated path already did. On 2026-11-23 this was the only reason the winget row read "error".

## Upkeep-NoAdmin

`Upkeep-NoAdmin.exe` is built with the cargo feature `portable`, which gives it an asInvoker manifest. It runs as you, sets `UPKEEP_USER_MODE=1`, and the engine then:

- lists and updates only winget packages installed for your account (`winget upgrade --scope user`), and names the apps installed for all users that have updates, without touching them;
- skips Windows Update, the 26H2 step, Chocolatey, G HUB, RustDesk and restoring startup services, and leaves out topgrade's Chocolatey, WSL, Tailscale, Office and PowerShell module steps;
- sets `__COMPAT_LAYER=RunAsInvoker`, so an installer that asks for elevation fails instead of prompting.

The Store, Steam, JDownloader, Claude Code and Codex, skills and the per-user topgrade steps run as usual. The dashboard hides the Install, New PC, Optimize and Startup & Services pages and the Driver Store tab, since each of them needs administrator rights.

Build it with `.\Build-Portable.ps1 -NoAdmin`. The release attaches it as `Upkeep-NoAdmin.zip`. It is not code-signed yet; the signing configuration covers `Upkeep.exe` only.

## Validation

- 204 PowerShell tests pass under Windows PowerShell 5.1. New tests cover holding the Chocolatey copies of apps winget updated, leaving Chocolatey a package winget failed on, and turning the hold off.
- 86 Rust tests pass in both builds.
- On the development PC, unelevated: the user-mode inventory listed only topgrade (installed for the account) and left out Git (installed for all users), and `Upkeep-NoAdmin.exe` opened with no UAC prompt. A full no-admin update run has not been done yet.
