# Upkeep 1.9.2

A network drive whose server is down no longer costs a run its skills and AI CLI updates, or minutes of waiting over SSH.

## The background

On a test laptop, the server behind two mapped network drives (one NFS, one SMB) was down. Windows reconnects saved drive mappings when you sign in, and Windows PowerShell checks every drive when it starts, so any Windows PowerShell started where those drives exist waited minutes before running anything. A test there, with a fake dead mapping, showed which sessions have the drives:

| Session | Drives seen |
|---|---|
| Your desktop, as your normal user | Local drives, the NFS drive and the test mapping |
| An SSH session | Local drives and the NFS drive |
| A scheduled task with no desktop (S4U) | Local drives only |

The elevated engine in the desktop session doesn't see them either. That's why winget and the other admin steps were never slowed down.

## Skills and AI CLIs update anyway

1.9.0 checks in 20 seconds whether Windows PowerShell starts for your normal user, and skipped the normal-user steps when it didn't. The Claude Code skills and the AI CLIs (Claude Code, Codex) now update from the engine's own process instead. It's the same account, with the same profile and the same files, and that process doesn't see the dead drives. Only the token differs: it has admin rights, which these updates don't mind. The log says when this happens. Winget packages whose installers refuse admin rights still need your normal user. They are listed with the reason, as before.

## Over SSH, the hand-off starts in a second

Started over SSH, the engine hands the run to your desktop session, because winget doesn't start in an SSH session. That hand-off used to start in Windows PowerShell inside the SSH session, and on the test laptop it waited 9 minutes on the dead drives before doing anything. It's now plain `cmd.exe` and `schtasks`. The scheduled task, elevated in your desktop session, writes the engine's output as numbered chunk files, which the SSH side prints in order, and then the exit code. On the test laptop the first line came back after 1 second and the engine's output after 3.

If the account isn't signed in to Windows, the SSH side now says so after 90 seconds and removes the task, so the update doesn't start later when someone signs in.

## Validation

- 182 PowerShell tests pass under Windows PowerShell 5.1. New tests cover: skills and AI CLIs updating in the engine's process when the normal-user check fails; the desktop side of the hand-off returning whole-line chunks, the run's settings and the exit code, for an engine in a folder whose path has spaces.
- A full run over SSH on the test laptop from this code took 2 min 18 s end to end, with nothing left behind: no scheduled task and no work folder.
