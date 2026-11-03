# Upkeep 1.8.7

Fixes the AI CLIs row, which 1.8.6 broke on every run, and two winget results seen on the test laptop the same day.

## The AI CLI step failed on every run in 1.8.6

1.8.6 set the default for `-SettingsPath` in `Update-AiClis.ps1` from `$PSScriptRoot` inside `param()`. Windows PowerShell 5.1 leaves `$PSScriptRoot` empty there when a script is started with `-File`, which is how both the engine and the dashboard start it. Every run stopped at `Split-Path : Cannot bind argument to parameter 'Path' because it is an empty string`, the AI CLIs row read `error`, and the dashboard's detection failed the same way, so the "Update with" choice never appeared. Both PCs showed it on 2026-11-03.

The default is now set in the script body. The tests had called the script with `&`, where `$PSScriptRoot` is set, so they missed it; a new test starts it with `-File` and no settings path, as the engine does, and fails on the 1.8.6 code.

## Battle.net is left to its own updater

winget cannot upgrade Battle.net: its manifest requires an install location, and winget stops with `-1978335137` "Install location is required by the package but it was not provided". Its version reads `Unknown`, so it was offered on every run and turned the winget row red on the test laptop twice on 2026-11-03.

The winget step now skips `Blizzard.BattleNet` with one line saying why. Battle.net updates itself when it starts, and Upkeep starts it after the updates. Skipping it also switches the step to per-package upgrades, because `winget upgrade --all` would still try it.

## A packaged app that finishes on restart says so

For ChatGPT, winget reports "Successfully installed. Restart the application to complete the upgrade." while the old version is still running. It was listed as an installer that "reports success, but Windows still lists the old version", and 1.8.5 would then have stopped running it. It is now listed as installed and waiting for the app to restart, with that as the fix, and it is not recorded as an installer that changes nothing.

## Validation

- 167 PowerShell tests pass under Windows PowerShell 5.1. Three are new: the AI CLI step started with `-File` and no settings path, Battle.net skipped without `--all`, and the restart case.
- Started with `-File` on this PC, the fixed step's detection returned Claude Code (npm 2.1.317, winget 2.1.302) and the Codex CLI, and the switch-only mode exited 4 without changes.
