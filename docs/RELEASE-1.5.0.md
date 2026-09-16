# Upkeep 1.5.0

## New PC setup

- Setup preview shows the chosen steps without installing apps or applying tweaks.
- Missing WinGet first tries App Installer registration, then Microsoft's
  `Microsoft.WinGet.Client` repair command. Chocolatey is prepared independently.
  Each bootstrap has a ten-minute limit; failures leave available installers usable.
- Apps use the catalog's Chocolatey mapping if WinGet is unavailable or fails.
  Installer launch exceptions and timeouts are recorded without stopping later apps.
  Exit 3010 is a successful install requiring a manual restart, not a reason to
  install a duplicate through another manager.
- Failed/deferred app installs can be retried from the New PC page. Successful apps
  from that report are excluded. Reports include a next action and installer logs.
- Defaults now install six essentials: 7-Zip, VLC, PowerToys, Notepad++, SumatraPDF
  and Brave. Other apps remain available in the catalog.
- Automatic driver replacement, O&O privacy changes, app removal, service changes,
  accessibility changes and broad debloat operations are opt-in. Explicit driver
  setup exports existing driver packages first and stops that phase if export fails.
  The machine-specific USB4 repair is no longer run automatically by setup.
- Registry toggles save their original values before writing. Setup persists each
  phase result and a transcript. Winutil selections run independently, with timeouts;
  retired selections are skipped and nonzero exits no longer count as success.
- A failed requested restore point defers winutil tweaks. System Restore is not
  described as a universal undo mechanism. O&O downloads require a valid signature.
- Pending servicing work is deferred for a manual restart and rerun. Setup no longer
  registers a task to apply changes automatically at next login.
- `-NoToggles` explicitly preserves an empty selection across Windows PowerShell
  argument passing. CLI driver installation requires `-InstallDrivers`.

## Updates and usability

- Preview available WinGet app updates in a review console without installing them.
  This preview does not cover Windows Update, Store, Steam or Topgrade.
- Retry failed WinGet app updates using the saved failed-app list, without a bulk
  update of unrelated packages. EA remains excluded by the existing restart guard.
- WinGet inventory uses column positions instead of English header names.
- Includes 1.4.2's responsive layouts, 80–200% text sizes and Windows display-language
  default, and 1.4.1's restart guards and bounded parallel client updates.

## Reports and rollback

Use **New PC > Reports and backups**, or open `%LOCALAPPDATA%\Upkeep\Reports`.
Each setup has a timestamped directory containing `results.json`, `setup.log`, and
backups for the actions actually performed. App reports are `apps-*.json`; previews
use a different filename prefix so they do not replace the latest install report.

To restore saved registry toggles, run in an elevated Windows PowerShell session
using the backup from the relevant setup run:

```powershell
& 'C:\Program Files\Upkeep\steps\Restore-SetupRegistry.ps1' -Backup 'C:\path\to\registry-before.json'
```

This restores existing values and removes values that did not previously exist.
It does not uninstall apps or reverse third-party scripts. Keep a personal file
backup before setup. `hosts-before.txt` and exported drivers are retained for manual
recovery where those phases ran.

## Validation and limits

61 Rust tests passed, including layouts at different zooms/resolutions in English
and Portuguese. Clippy and rustfmt passed. 79 PowerShell tests passed across the
full suite and subsequent targeted reruns, including missing managers, exceptions,
fallbacks, exit 3010, failed-only retries, translated inventory, malformed config,
empty toggle selection and registry rollback. Installer tests use fakes; they do
not update the host PC. Setup and app-pack dry runs also completed.

Not yet verified in a clean Windows VM or against every real third-party installer.
Internet access, administrative rights and vendor availability are still required.
The app never requests a restart in these paths, but cannot guarantee that an
arbitrary third-party installer honors that choice. The known EA installer is
excluded. Preview/results currently use a console and saved reports; a unified
in-app result table remains a useful next improvement.

## Useful next additions

- Optional password-manager selection (Bitwarden is already in the catalog).
- A guided personal-file backup and restore check before optimization.
- Read-only security checks for Windows Update, Defender, firewall and encryption,
  with explanations and direct links to Windows Settings.
- Manufacturer-specific driver guidance instead of broad automatic replacement.
- Measured per-step durations and parallel downloads, keeping installations that
  share Windows Installer/servicing locks serialized.
