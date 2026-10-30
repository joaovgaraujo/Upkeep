# Upkeep 1.8.4

Fixes for the four errors that showed up on almost every run between 2026-10-22 and 2026-10-28. None of them was an update that could not be installed. Each was a program in use, or an installer whose success winget could not see.

## topgrade's uv step no longer waits on running uv servers

topgrade's `uv` step failed on all four runs in that week. It finishes with `uv cache prune`, which needs uv's cache to itself, and every running `uv run` or `uvx` process holds that cache shared. On this PC nine copies of an MCP server started with `uv run` were still running, some for four days. The log shows "Cache is currently in-use, waiting for other uv processes to finish", then a 300-second timeout, then `uv: FAILED`.

When uv processes are running, `steps\Protect-InUsePackages.ps1` now passes `--disable uv` to topgrade for that run and runs `uv tool upgrade --all` itself, which does not need the exclusive lock. Only the cache cleanup is skipped. The engine reads the extra argument from `%LOCALAPPDATA%\SystemUpdate\topgrade-extra-args.txt`, which the release step removes after topgrade.

## Git for Windows is held back in winget too

Git's installer cancels itself while any program from its folder is running ("The following process(es) use Git for Windows ... Defaulting to Cancel for suppressed message box"). 1.8.1 held the Chocolatey package back in that case, but this PC also tracks Git through winget as `Git.Git`, and winget failed it on 2026-10-24, -26 and -28. The winget step no longer starts that installer while Git is in use. It lists Git under "Needs a manual update" with the processes holding it open.

Those processes are counted by name now (`bash.exe x42, sleep.exe x10`) instead of listed by PID. Terminal sessions and Claude Code sessions had left enough Git Bash helpers running that one line in the 2026-10-22 log named about 120 PIDs.

## An installer that reports success is not counted as a failure

Logitech G HUB and ChatGPT returned exit code 0 twice per run, and winget still listed the old version afterwards. Those apps finish updating themselves after launch, or report a version winget can't match. Running the same installer again on the next run changes nothing, so they are listed under "Needs a manual update" instead of turning the winget row red.

## The Store row ignores apps that are open

The Store reported `0x80073D02` ("resources it modifies are currently in use") for the Codex app on 2026-10-24 and -26, and the Store row read `error`. An open app now goes on the manual-update list, saved to `Reports\manual-updates-store.json`. The Store usually finishes these updates in the background once the app is closed.

## Two manual updates from one step print as two entries

When one step listed more than one app, the end-of-run list merged them into a single entry with both names, both reasons and both fixes on one line, and counted them as one. Windows PowerShell 5.1 passes a JSON array through `ConvertFrom-Json` as a single object, and `Show-ManualUpdates.ps1` added it as one item. Each app now gets its own entry.

## Validation

- All 159 PowerShell tests passed, with the step scripts running under Windows PowerShell 5.1. Six are new: Git.Git held back while Git is in use, an installer that reports success without moving the version, topgrade's uv step skipped while uv processes run, the same step left alone when none run, the extra topgrade argument removed on release, and two apps from one report printed as two entries.
- `topgrade --dry-run --disable uv` (topgrade 17.14.1) leaves out the uv step, which the same dry run without the flag includes.
- A full run on the PC whose logs showed these errors: winget did not start Git's installer (49 bash.exe were running), listed Git and G HUB for a manual update, and read `ok - some apps need a manual update`. topgrade skipped its uv step with 9 uv processes running and read `ok`. Windows Update, Store, Steam and the AI CLIs read `ok`. That run also showed the merged-entry bug above, which is fixed and tested since.
