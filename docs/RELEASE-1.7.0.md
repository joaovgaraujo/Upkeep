# Upkeep 1.7.0

Full updates now start with Windows Update, Microsoft Store, Steam, developer tools and other supported app updaters selected. These services are visible in the main update page, rather than hidden as optional extras. WinGet still provides the app preview; each other provider detects its own updates during execution. Existing provider support and engine exclusions are unchanged.

The review action appears above the app list after a successful scan. Failed scans cannot silently proceed with an incomplete full-update plan. Empty WinGet results explicitly explain that selected services still run.

The confirmation now uses one scroll viewport, a wider responsive layout, visible package identifiers, separate installed/new versions, select-all/clear controls, and fixed confirmation/back actions. The app picker also reserves enough height for multiple rows. Long lists can be scrolled without losing the confirmation buttons.

Pins, ignored WinGet packages, EA protection and reboot safeguards remain in place. The confirmation explains that other package managers can update apps unchecked in the WinGet list.

Validation covers long lists, both languages, small windows and high zoom, default full-update selection, and cancellation without starting the engine. No real system or application updates are run during validation.

Release checks: 71 Rust tests passed (one live network test intentionally ignored), 118 PowerShell tests passed, formatting and Clippy with warnings denied passed. Layouts were rendered and inspected using synthetic app inventories.
