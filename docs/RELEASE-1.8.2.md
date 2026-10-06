# Upkeep 1.8.2

Apps that winget cannot update on this PC are now listed at the end of the run with the reason and the fix, instead of turning the winget and topgrade rows red. Claude Code and the Codex CLI are updated through whichever channel installed them.

The v1.8.1 tag was never published: one test failed on GitHub's runners, so the release workflow stopped before building. 1.8.2 is that release plus the test fix.

## Apps that need a manual update are listed, not failed

A run on this PC on 2026-10-06 ended with `winget : error` and `topgrade : error`, and none of the five causes was a broken update. Each one was traced through the installer's own log:

- **Epic Games Launcher**, MSI exit 1603. Its LaunchCondition reads "Epic Games Launcher is currently running", and the engine starts Epic before the winget pass. The winget step now closes `EpicGamesLauncher` and `EpicWebHelper` before upgrading and starts the launcher again with `-silent`.
- **Git for Windows** through Chocolatey, exit 1. Setup's log shows "The following process(es) use Git for Windows: bash.exe ... Defaulting to Cancel for suppressed message box", so one open Git Bash failed topgrade's whole Chocolatey step. `steps\Protect-InUsePackages.ps1` now pins `git.install` for the run when anything from the Git folder is running, names those processes, and removes the pin after topgrade. A pin left by a killed run is removed at the start of the next one. Upkeep never kills the processes.
- **Zed**, "No applicable upgrade found". Zed installs per-user with Inno Setup, while its winget manifest declares a machine-wide installer. The winget step downloads the installer with `winget download` (manifest hash checked), requires a valid Authenticode signature, and runs it with `/CURRENTUSER` as the normal desktop user.
- **Microsoft Edge**, install technology changed. The old message told users to uninstall Edge with winget. Edge is now never upgraded through winget: the step asks EdgeUpdate for an on-demand install of the stable channel, which updates in place. On this PC the `MicrosoftEdgeUpdate*` scheduled tasks had been deleted, so Edge had stopped updating itself.
- **Sunshine**, install technology changed, from NSIS to WiX. This one is not automated, because the uninstall can take the configuration in `C:\Program Files\Sunshine\config` with it.

Whatever is still pending for one of these structural reasons goes to `Reports\manual-updates-<source>.json` instead of the error count. `steps\Show-ManualUpdates.ps1` prints the list, with the reason and the fix for each app, just before the summary block. It goes before the summary because the dashboard closes the engine 65 seconds after the summary appears. The winget step exits 3 in that case and the summary reads `winget : ok - some apps need a manual update`. These apps stay out of `winget-failed.json`, since retrying them changes nothing. Genuine installer failures are still errors.

## Claude Code and Codex CLI

topgrade's `node` step is disabled in the generated config, so npm-installed CLIs were never updated, and the native installs only update through their own `update` command. `steps\Update-AiClis.ps1` finds each install and updates it through the same channel:

| Install | Update |
|---|---|
| npm global (`@anthropic-ai/claude-code`, `@openai/codex`) | `npm install -g <package>@latest`, skipped when `npm view` reports the installed version is already the newest |
| Claude Code native (`~\.local\bin\claude.exe`) | `claude update` |
| Codex standalone (`%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`) | `codex update` |
| winget, Chocolatey, Scoop, Store | left to those steps |

The updates run as the normal desktop user, because all of these installs live in the user profile. `codex update` starts Windows PowerShell 5.1, and launched from a PowerShell 7 session it inherited PS7's `PSModulePath` and failed with "Get-FileHash is not recognized". The step resets the module path first. A failed update, for example npm hitting `EBUSY` while the CLI is running, is listed for a manual update with the command to run.

## Validation

- All 150 PowerShell tests passed, 13 of them new: the winget scenarios for an installer-type change, Edge and a genuine failure, closing Epic, the end-of-run list, holding and releasing the Git pin, and the npm path of the CLI step.
- Three tests in `tests/FeatureUpdate.Tests.ps1` had depended on the test machine's real pending-restart flag and failed whenever a restart was pending. Tests that substitute the job bodies now ignore that flag, and a dry run reports a pending restart and continues instead of stopping.
- A full elevated engine run on Windows 11 25H2 (26200.9457) with the 26H2 enablement package staged reported `ok` for winget, AI CLIs, topgrade, Windows Update, Store, Steam and JDownloader, and `ok - restart required` for the feature update.
- The npm test for the CLI step passed locally but failed on GitHub's runners, which run elevated. The step loads `Deelevate.ps1`, which replaced the test's stub of `Test-Elevated`, so the update went through the de-elevated worker and never reached the fake npm. The stub is now appended to the test's copy of `Deelevate.ps1`, as the winget tests already do.
- `release.yml` published every release with `docs/RELEASE-1.7.2.md` as its body, so the 1.8.0 release page showed the 1.7.2 notes. It now uses the notes file matching the tag.
