# Upkeep 1.5.1 — restart and finish setup

This release also includes the improvements developed since GitHub 1.4.0:
responsive layouts and Windows display-language defaults, robust new-PC setup with
WinGet/Chocolatey recovery, preview and failed-item retry, registry backups,
conservative optimization defaults, EA restart safeguards and parallel client updates.
See [1.5.0](RELEASE-1.5.0.md), [1.4.2](RELEASE-1.4.2.md) and
[1.4.1](RELEASE-1.4.1.md) for those changes.

Setup and app installation now offer a restart prompt when selected work needs
a restart. This replaces 1.5.0's manual-rerun-only behavior.

| Choice | Result |
| --- | --- |
| Yes | Save unfinished work, register continuation, then request a restart now. Save personal work first. |
| No | Save and register continuation; you restart manually whenever convenient. |
| Cancel / close | Do not register continuation or restart. Retry manually from Upkeep later. |

Only explicit **Yes** requests a restart. The command does not force applications
closed. Failure to save the payload or register its task prevents a restart.
The prompt uses Portuguese or English according to the Windows UI language.

## What resumes

- Only apps marked as blocked by a restart and deferred servicing tweaks.
- Apps already installed successfully are not added to the continuation list.
- An installer returning 3010 can request a final restart without reinstalling it.
- Ordinary download/installer failures and the manual-only EA installer are not
  silently retried as reboot work.
- At sign-in, a boot-time check distinguishes a real restart from sign-out/sign-in.
  The task runs once after a new boot and is removed before applying changes.
- If Windows still reports pending servicing, continuation stops with a saved
  explanation. If later work requires another restart, it asks for approval again.
  No automatic reboot loop or repeated installation at every sign-in.

Use **Manage restart continuation** on Update or New PC to restart now, leave a
previously approved job scheduled, or cancel scheduled continuation.

## WSL and Docker

Selecting Docker Desktop or the new optional WSL catalog entry prepares the WSL
and Virtual Machine Platform features with `-NoRestart`. If enabling them needs a
restart, the dependent app waits; unrelated apps continue installing first.
After restart, setup installs/updates the modern WSL runtime without creating or
launching a Linux distribution, then continues the selected app installation.

Linux username/password creation, Docker's first-run terms, and firmware
virtualization settings still need user interaction when applicable. Upkeep does
not accept terms or change firmware settings on your behalf.

References: [Microsoft WSL commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands),
[WSL installation](https://learn.microsoft.com/en-us/windows/wsl/install),
[Docker Windows requirements](https://docs.docker.com/desktop/setup/install/windows-install/).

## Durability and reports

Approved continuations copy the required scripts, catalog, settings and presets
into `%ProgramData%\Upkeep-Resume\<job-id>`. This directory is writable only by
Administrators and SYSTEM. Moving the portable folder therefore does not break
the task, and the elevated task does not execute a script from a writable USB or
Downloads folder. Registration uses the current user's interactive sign-in, with
a 30-second delay; no password is stored. Duplicate pending jobs are refused.

The saved state contains the originating boot, exact pending selections and result.
The completed/blocked state is copied to `%LOCALAPPDATA%\Upkeep\Reports`, alongside
the normal detailed setup/app reports. Cancellation preserves the job for inspection.

## Validation

23 targeted Windows PowerShell tests passed: approval/cancel/later, registration
failure, duplicate refusal, changed boot versus sign-out, one-shot continuation,
pending servicing, WSL feature sequencing, native runtime commands, exact app
selection, plus the existing new-PC fault and rollback cases.
61 Rust tests, Clippy and rustfmt passed, including both-language responsive layouts.

These tests simulate boots, installers, task registration and Windows servicing.
No actual restart, feature enablement or package installation was performed on the
development PC. A complete clean-VM reboot/install cycle remains unverified.
