# Upkeep 1.8.9

Faster winget runs, updates that work over SSH, and everything from 1.8.8. 1.8.8 was tagged, but its build stopped on a test problem, so it was never published: its Claude Code skills, G HUB and NVIDIA changes ship here. They are described in [RELEASE-1.8.8.md](RELEASE-1.8.8.md); the short version is at the end.

## winget installs in two lanes

Installing winget updates one at a time was 70 to 75% of a run (8 of 11 minutes on 2026-11-05). Windows Installer runs one MSI at a time, but EXE, Inno, Nullsoft, portable and MSIX installers don't use it. When two or more packages are pending, the step reads each one's installer type (`winget show`, several at once). It then installs the non-MSI ones in a second lane that runs alongside the first. Packages with special handling stay in the first lane: apps closed before they update, apps held while in use, apps that update themselves, and winget itself. A second-lane install that still runs into "another installation is in progress" is installed again on its own at the end. `UPKEEP_WINGET_SERIAL=1` turns the second lane off.

On the test laptop on 2026-11-07, 4 of 11 packages (Telegram, MPC-HC, K-Lite, Signal) ran in the second lane, with no Windows Installer conflicts.

## topgrade's quick steps run during winget

rustup, cargo, juliaup, julia, pip3, pnpm, the GitHub CLI steps, Claude Code plugins, MiKTeX and Tailscale don't install anything through Windows Installer. The winget step now starts them right after its scan, alongside the installs. It leaves out a step whose tool winget is about to update in the same run: pip3 while Python updates, rustup while Rustup updates, and so on. The main topgrade run then skips those steps (`--disable`), so it only runs Self update, WSL, Chocolatey, the editor extensions and Skills. If a quick step fails, the topgrade row still shows it.

## One winget scan instead of two

The engine ran a second full `winget upgrade` scan only to find the packages that need explicit targeting. The winget step now writes that list from its own scan, which saves 10 to 20 seconds per run.

## Runs work over SSH

An SSH session has no desktop. winget is a packaged app and does not start there: the command alias and the real `winget.exe` both failed with "Access is denied", so the first step stopped the run. When the engine sees `SSH_CONNECTION`, it now starts itself again, elevated, in the session where the same account is signed in. It does this through a one-off scheduled task (`steps\Invoke-InDesktop.ps1`), streams that run's output back to the SSH window, and returns its exit code. The account must be signed in to Windows, at the PC or over Remote Desktop. Stopping the SSH command doesn't stop the run.

Two changes make that work:

- The single-instance guard counted the waiting SSH-side engine as a second engine and refused to start. The relay now passes its process ID, and the guard ignores that one process.
- Normal-user updates looked for a desktop only in their own session. They now also accept a desktop in another session signed in by the same account. Another account's desktop still doesn't count.

On the test laptop, a full run over SSH now updates winget, the Store, Steam, JDownloader and the AI CLIs. ProcessMonitor, which needs a normal-user install, upgraded unelevated.

## Shorter waits

- **Claude Code's own installer:** `claude update` is skipped when the installed version is already npm's newest. A normal-user AI CLI update is waited on for 5 minutes instead of 15. On the test laptop `claude update` took about 15 minutes, and the whole run waited for it. After 5 minutes the update now carries on in the background, and the run continues.
- **G HUB:** the updater gets 2 minutes instead of 8. With G HUB open, this PC applied its downloaded build within seconds. On the test laptop, with G HUB closed, the build was not applied in 8 minutes, nor after a service restart. That case now ends after 2 minutes, with a note that G HUB applies the build the next time it is opened.
- **Quick topgrade exit code:** reported correctly now. It printed an empty value because .NET drops the exit code of a process whose handle was never read.

## From 1.8.8

- Claude Code skills in `~\.claude\skills` are updated from their source. That source is GitHub through `gh skill` (Matt Pocock's skills, officecli, rossmann-voice), any git repo (blader/humanizer, or your own under `AgentSkillRepos`, with Gitea read through `GITEA_TOKEN`), or graphify's installer. Edited skills are left alone, replaced copies are backed up first, and Confirm updates can keep any skill as it is. A watched upstream (no-ai-slop) is reported when it changes.
- G HUB's updater service is started for the update and put back as it was, so a disabled service no longer leaves downloaded builds unapplied.
- A newer NVIDIA driver is listed at the end of the run, with an "Open NVCleanstall" button.

## Validation

- 176 PowerShell tests pass under Windows PowerShell 5.1. New since 1.8.8: an MSI and a non-MSI package installed in two lanes, a second-lane install retried alone after "another installation is in progress", and the skills tests fixed for CI (git's line-ending warning on stderr had stopped them there).
- 77 Rust tests pass.
- On the test laptop, a full update over SSH: the run moved to the desktop session; 11 winget packages with 4 in the second lane; quick topgrade steps alongside winget, with the main topgrade run then taking 14 s; Store, Steam, JDownloader and the AI CLIs updated.
