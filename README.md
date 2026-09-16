# Upkeep

**English** | [Português (BR)](README.pt-BR.md)

Update everything on a Windows PC from one window, and set up a new one from
scratch.

Upkeep is a Rust/egui dashboard wrapping a batch engine that drives
[topgrade](https://github.com/topgrade-rs/topgrade), winget, Chocolatey,
Windows Update, the Microsoft Store, Steam and JDownloader. It also ships a
new-PC path: restore point, tweaks, drivers, and an app catalog with presets.

## Read this before running it

**Upkeep runs elevated.** The GUI carries a `requireAdministrator` manifest and
the engine inherits that elevation, because installing updates system-wide
needs it. That has consequences worth understanding:

- **It executes remote scripts as administrator.** The "winutil" tweak path
  defaults to `irm https://christitus.com/win | iex`, and Chocolatey is
  bootstrapped from `community.chocolatey.org/install.ps1`. Both are the
  upstream projects' own documented install methods, and both are triggered
  by you rather than run silently, but they are remote code execution as
  admin, and you should be comfortable with that before using those features.
- **It auto-installs tooling** it depends on: Chocolatey, topgrade, and the
  `PSWindowsUpdate` PowerShell module.
- **Game launchers started from Upkeep inherit administrator rights** for the
  session, and so do games launched from them. If that matters to you, start
  launchers yourself instead of using the launcher step.

## Defaults you may want to change

- **Interface defaults follow Windows.** A new settings file uses the Windows
  display language (English or Portuguese, with English fallback) and the
  Windows accessibility text size. Use **Appearance & language** to change
  these; **Follow Windows** restores automatic language selection. Existing
  saved language choices are preserved. Navigation and cards adapt to window
  size and zoom; wide data tables can scroll horizontally.

- **EA updates are manual.** An EA installer initiated an unwanted Windows
  restart during a winget upgrade. Upkeep now enforces an EA blocking pin in
  winget and an `ea-app` pin in Chocolatey before updating applications. It
  also stops automatically launching or reinstalling EA. If either guard
  fails, the run stops. Update EA manually when you can tolerate a restart.
- **Windows Update has one owner.** Topgrade's `system` step is disabled;
  the explicit Windows Update step uses `-IgnoreReboot`, and Topgrade's
  `updates_auto_reboot` is explicitly `"no"`. These controls do not override
  independent Windows restart schedules or every third-party installer.
- **Independent clients run together.** Store, JDownloader and Steam run in
  up to three hidden workers after package managers and Windows servicing
  finish. Each worker has a timeout; results and output are retained in the
  run log. Package managers stay sequential to avoid installer contention.
- **Failed steps now report failure.** Topgrade errors and unresolved winget
  upgrades appear as errors in the summary and produce a nonzero engine exit.

- **Pins: read this one.** A pinned package stops receiving updates,
  *including security updates*. Four packages ship pinned, for two different
  reasons:
  - **Adobe Acrobat Reader** (`.64-bit`, `.32-bit`, `Acrobat.Pro`, and the
    Chocolatey equivalents) is pinned **by the author's preference**, not for
    any technical reason. Acrobat is a frequent target for exploited
    vulnerabilities, so leaving this in place means running a knowingly
    outdated PDF reader. **If you are not the author, you probably want to
    remove it**, either from the Pins tab or with:
    ```
    winget pin remove --id Adobe.Acrobat.Reader.64-bit
    choco  pin remove -n=adobereader
    ```
  - **MiKTeX** and **Heroic** are pinned because their own updaters are
    broken; pinning removes a guaranteed per-run failure and costs nothing.
- `apps.json` and `presets/` are a curated catalog, not a recommendation.
  Read them before running the new-PC path.

## On a freshly installed PC

The new-PC path is built to keep going when a fresh Windows install is only
half ready, instead of hanging on the first thing that is missing:

- **No Visual C++ Redistributable needed.** The C runtime is linked into
  `Upkeep.exe`.
- **No GPU driver needed.** Without OpenGL 2.0 (e.g. still on "Microsoft Basic
  Display Adapter") the GUI falls back from OpenGL to DirectX 12, which also
  runs on Windows' software renderer. Any other startup failure shows an error
  box instead of the window silently never appearing.
- **Restart pending (Windows Update).** The few winutil tweaks that go
  through Windows servicing (Recall removal, component cleanup, reserved
  storage, optional features) are deferred. A prompt offers restart now,
  continuation after a later manual restart, or cancellation. Only approved
  continuation runs after the next restart and sign-in. Installers that enable Windows
  features (Docker Desktop, WSL and WSL distros) are skipped with a message
  until you restart.
- **Nothing waits forever.** winutil (`WinutilTimeoutMin`, default 20), each
  app install (`AppInstallTimeoutMin`, 30) and SDIO (`SDIOTimeoutMin`, 45) run
  under a time limit; a stuck process tree is stopped and the run continues.
- **SDIO download server unreachable** (happens from some Brazilian networks):
  SDIO is skipped when it would have to download and its server does not
  answer; Windows Update and the PC maker's updater still provide drivers.
- **Intel Thunderbolt driver on USB4 controllers.** SDIO installs Intel's
  standalone Thunderbolt driver on controllers meant for the Windows inbox
  USB4 driver, which disables the port. Setup now leaves driver replacement
  off by default and does not automatically apply the machine-specific
  `Repair-Usb4Driver.ps1`; that tool remains available separately.
- **winget missing** on a new install: App Installer is registered first, then
  Microsoft's WinGet repair module is tried. Chocolatey is prepared independently
  and used as a catalog-based fallback. Failures are recorded per app.
- **Preview, retry and recovery:** see [1.5.0 release notes](docs/RELEASE-1.5.0.md)
  for conservative defaults, failed-only retries, reports and registry rollback.
  [1.5.1 adds opt-in restart continuation](docs/RELEASE-1.5.1.md), including
  WSL feature preparation before Docker installation.

## Optional: startup timings

The Startup page can show how long each startup item takes. That data is not
shipped: it would be one machine's numbers presented as if they were yours,
so the Time column stays blank until you supply `boot-times.json` next to the
executable:

```json
{
  "_comment": "seconds per startup item; matched case-insensitively by name",
  "some background service": 4.7,
  "another autostart app": 1.1
}
```

Keys are lowercased item or display names; per-user suffixes like `_223a20`
are stripped before lookup. A missing or malformed file is ignored.

## Building

Requires a Rust toolchain (MSVC) and, for the installer, Inno Setup 6.

```powershell
cd gui
cargo build --release          # produces gui\target\release\Upkeep.exe
cargo test --release           # GUI and engine tests

.\Build-Portable.ps1           # dist\Upkeep-Portable.zip + dist\Upkeep\
.\Build-Installer.ps1          # dist\Upkeep-Setup.exe
```

The exe finds its resources by walking up from its own directory looking for
`SystemUpdate_Topgrade.bat`, so the portable folder works from anywhere.

## Layout

| Path | What it is |
| --- | --- |
| `gui/` | Rust/egui dashboard (`dashboard_core` lib + `Upkeep` bin) |
| `SystemUpdate_Topgrade.bat` | the update engine; runnable standalone |
| `steps/` | Store, Steam, JDownloader, winget and launcher steps |
| `Setup-NewPC.ps1` | one-shot new-PC setup |
| `Repair-Usb4Driver.ps1` | removes a wrong Intel Thunderbolt driver from USB4 controllers |
| `Install-Apps.ps1`, `apps.json`, `presets/` | app catalog and installer |
| `installer/` | Inno Setup script |
| `UpdateDashboard.ps1`, `Functions.ps1` | legacy WPF dashboard, superseded |

## Status

Personal project, shared in case it is useful. It is developed against one
Windows 11 machine, so paths and assumptions elsewhere may need adjusting.
No warranty. See [LICENSE](LICENSE).
