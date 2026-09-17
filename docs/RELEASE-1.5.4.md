# Upkeep 1.5.4

The Update page now offers **Check for updates** with a WinGet checklist showing
app names and installed/available versions. Nothing is selected initially.
**Update selected apps** runs only those WinGet packages, under the engine lock,
with a saved log and the existing stop control. It does not run Windows Update,
Store, Chocolatey, developer tools or launcher updates.

**Ignore** persists a WinGet ID in `%LOCALAPPDATA%\Upkeep\winget-ignore.json`.
Ignored IDs are excluded from Upkeep's WinGet inventory, automatic upgrades and
failed-item retries. **Restore** removes an ID and checks again. This is scoped
to WinGet: independent app self-updaters and other package managers are separate.
Existing blocking WinGet pins remain respected. Explicit-targeting packages
such as Anaconda stay outside this checklist and retain their existing workflow.

The category action is now labeled **Update checked categories**. Results and
Summary show successful app upgrades alongside per-app failures, counts and
next steps for apps in use or changed installer types. A nonzero exit following
a completed summary is presented as completed with issues, not a total failure.

Includes the 1.5.3 abandoned-engine-lock recovery fix.
