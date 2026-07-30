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
cargo test --release           # 58 tests

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
| `Install-Apps.ps1`, `apps.json`, `presets/` | app catalog and installer |
| `installer/` | Inno Setup script |
| `UpdateDashboard.ps1`, `Functions.ps1` | legacy WPF dashboard, superseded |

## Status

Personal project, shared in case it is useful. It is developed against one
Windows 11 machine, so paths and assumptions elsewhere may need adjusting.
No warranty. See [LICENSE](LICENSE).
