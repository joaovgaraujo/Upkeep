# Upkeep 1.8.3

Four fixes from the update logs of 2026-10-06 and 2026-10-07. In each case the summary showed `error`, or a message that was wrong, for a problem that was transient or that Upkeep caused itself.

## Windows Update retries a failed pass once

One run installed about twenty updates (Defender, drivers, Intel and Realtek components), then PSWindowsUpdate threw `Exception from HRESULT: 0x80248007` and the Windows Update row read `error`. That code is usually transient. A failed pass now runs a second scan, which installs whatever the first one left. The first pass's errors are logged as `[warn]`, and the row only reads `error` when the second pass fails too. A timeout is not retried, because the time budget is already spent.

## The 26H2 step no longer asks for a restart that would not help

KB5121794 needs build 26200.9550 or newer (KB5124010). On a machine at .9457, Windows Update reported `Found [0] Updates`, and the step still said "Prerequisite updates are staged. Restart Windows, then run the upgrade again." Nothing had been staged, so a restart would have changed nothing. When the build does not move and nothing is waiting for a restart, the step now says Windows Update did not offer the prerequisite. It lists the KB under "Needs a manual update", saved to `Reports\manual-updates-feature.json`, and the row reads `ok - needs a manual update`.

## App Installer is not installed twice

App Installer (`Microsoft.AppInstaller`) is winget itself. Its upgrade returned 0, but every winget query for the rest of the run still listed the old version. The step then installed it a second time and reported it as still pending, so the winget row read `error`. A successful App Installer upgrade is now taken at its word, and the next run shows whether it took. A pending App Installer also switches the winget pass to per-package upgrades, so its exit code is known.

## Claude Code is updated once per run

topgrade's `claude_code` step ran `claude update` right after `steps\Update-AiClis.ps1` had already updated Claude Code. That step is now disabled in the generated topgrade config. `claude_code_plugins` stays on, since nothing else updates the plugin marketplaces.

## Validation

- All 153 PowerShell tests passed in Windows PowerShell 5.1, 3 of them new: a Windows Update retry that recovers, a 26H2 prerequisite that was not offered, and an App Installer upgrade that winget keeps listing.
- A topgrade dry run with the generated `disable` list no longer includes the Claude Code step, and still runs Claude Code Plugins.
- The feature-update tests now write their reports to a scratch folder instead of `%LOCALAPPDATA%\Upkeep\Reports`.
