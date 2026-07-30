# Upkeep (Rust GUI)

A dark, modern eframe/egui dashboard that wraps `SystemUpdate_Topgrade.bat`,
replacing the PowerShell/WPF `UpdateDashboard.ps1` GUI. It is a drop-in
sibling of the batch engine: same `settings.json`, same pin-list format
inside the `.bat`, same log/summary contract.

## Building

```
cargo build --release
```

(run from this `gui\` directory). First build downloads and compiles ~400
crates and takes a few minutes; incremental rebuilds are fast.

The exe lands at:

```
gui\target\release\Upkeep.exe
```

To run the unit tests (pure parsing/validation logic — pins, driver-store
output, engine summary parsing):

```
cargo test --release
```

`cargo fmt` is configured and safe to run from this directory.

## Elevation

`Upkeep.exe` has a `requireAdministrator` manifest embedded by
`build.rs` (via the `embed-manifest` crate), so double-clicking it pops the
single UAC prompt itself. Its child process (`cmd.exe /c
SystemUpdate_Topgrade.bat`) then inherits that elevated token and never
triggers its own UAC prompt, even though the .bat itself contains a
self-elevation check (that check is a no-op once already elevated).

Because of that manifest, the exe (and anything that shares its name) always
demands elevation to launch — including from an unelevated dev shell. The
library code (parsing, settings, pins, drivers, engine plumbing, UI) lives in
a separate `dashboard_core` lib target (`src/lib.rs`) with **no** embedded
manifest, specifically so `cargo test` can run unelevated; `main.rs` is a
thin wrapper with `test = false` set on its `[[bin]]` entry so `cargo test`
doesn't also try to launch the elevated exe.

## Root / settings resolution

On startup the app looks for `SystemUpdate_Topgrade.bat` by walking upward
from the executable's own directory (so it works from
`gui\target\release\` during development, and from wherever the exe is
placed in production), then falls back to the current working directory and
its ancestors. The first directory found containing the .bat becomes the
"root". `settings.json` is read/written next to the .bat in that root — the
same file the PowerShell dashboard uses.

If no root can be resolved, the app still opens; a warning banner explains
the .bat wasn't found and the Run button stays disabled.

### settings.json schema

All keys from the existing PowerShell dashboard are preserved:
`SDIOPath`, `NVCleanPath`, `RAPRPath`, `JDownloaderPath`, `SteamPath`,
`SDIOScanTimeoutSec`, `DriverQueryTimeoutSec`, `StaleOutputWarnSec`.

Two new optional keys are added:
- `NVCleanPackagePath` — path to a pre-built NVCleanstall unattended package
  exe (built via NVCleanstall's own "Build Package" feature). When set, the
  Tools tab's "NVCleanstall — Recommended Update" button runs it unattended
  (`-y -noreboot`) instead of opening the interactive GUI.
- `WinutilCommand` — the PowerShell one-liner run by "Open winutil".
  Defaults to `irm https://christitus.com/win | iex`.

Any other keys already present in `settings.json` (or added by the
PowerShell dashboard in the future) round-trip untouched — the Rust struct
uses `#[serde(flatten)]` into a JSON map for anything it doesn't model.

## Architecture

- `src/main.rs` — thin entry point: sets up the eframe window and hands off
  to `dashboard_core::app::DashboardApp`.
- `src/lib.rs` — the `dashboard_core` library crate (see Elevation above).
- `src/app.rs` — `eframe::App` implementation: all UI (sidebar, tabs,
  banners, dialogs) and the app state machine.
- `src/engine.rs` — spawns the `.bat` hidden (`CREATE_NO_WINDOW`), streams
  stdout/stderr line-by-line on a background thread, strips ANSI, detects
  `[tag]` markers and the `====...` summary block, and sends everything back
  to the UI thread over a single `mpsc::Sender<AppEvent>`. Also owns the
  post-summary watchdog (kills the engine ~65s after the summary block
  closes, since the .bat's own `timeout /t 60` would otherwise wait forever
  for a keypress that a headless spawn will never produce).
- `src/settings.rs` — settings.json load/save + root resolution +
  best-effort autodiscovery of tool paths (SDIO, NVCleanstall, RAPR,
  JDownloader, Steam) when a configured path is empty or missing.
- `src/pins.rs` — parses/validates/rewrites the `winget pin add` / `choco
  pin add` block inside the .bat (port of `Get-PinListFromBat` /
  `Set-PinListInBat` / `Test-PinId` from `Functions.ps1`), with a `.bak`
  backup before every save.
- `src/drivers.rs` — runs `pnputil /enum-drivers` hidden with a timeout
  watchdog and parses its text output (port of `ConvertFrom-PnpUtilOutput`).
- `src/reboot.rs` — pending-reboot registry checks (CBS RebootPending, WU
  RebootRequired, PendingFileRenameOperations), all degrading to `false` on
  any error rather than panicking.
- `src/theme.rs` — dark "slate/graphite" visuals, seeded from
  catppuccin-egui's Mocha palette then retuned to a neutral grey with a
  green accent reserved for the Run button and per-category status colors.

## Deviations from the original spec / notes

- **`EngineExited(i32)` sentinel**: if the post-summary watchdog has to kill
  the engine (because it's still sitting on the .bat's `timeout /t 60`), the
  true process exit code is unknowable. `-1` is sent in that case; the
  bottom status bar shows "Finished (watchdog stopped engine)" rather than
  claiming a fabricated exit code.
- **No dedicated Settings-editing tab**: the 5 required tabs (Log, Summary,
  Tools, Pins, Driver Store) don't include a settings editor, matching the
  original WPF dashboard's approach (paths are autodiscovered or edited in
  `settings.json` directly). The read/preserve-unknown-keys/write plumbing
  is fully implemented in `settings.rs` and used on startup; wiring a UI
  editor to it would be a small addition if wanted later.
- **`AppEvent::RebootStatus` is currently unsent**: pending-reboot checks are
  fast synchronous registry reads, done directly on the UI thread on startup
  and again right before a run, so the async event variant (present per the
  spec'd enum shape) is reserved for a future periodic/background poll.
- **SDIO executable resolution** prefers a filename containing `X64` (this
  machine's expected case) and falls back to any `SDIO*.exe` in the
  configured folder; this collapses the PowerShell version's separate
  32-bit-OS branch, since a 32-bit path is not a realistic target here.
- **pnputil output decoding** uses `String::from_utf8_lossy` rather than
  detecting the console's OEM code page; acceptable since driver/class names
  are overwhelmingly ASCII in practice.
- **Log rendering performance**: the Log tab uses egui's
  `ScrollArea::show_rows` virtualization (only visible rows are laid out
  each frame) rather than one-widget-per-line for the whole 10k-line buffer.

