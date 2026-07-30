//! Settings persistence: reads/writes the same `settings.json` used by the
//! PowerShell dashboard, preserving any keys it doesn't know about.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const BAT_NAME: &str = "SystemUpdate_Topgrade.bat";
pub const DEFAULT_WINUTIL_COMMAND: &str = "irm https://christitus.com/win | iex";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    #[serde(rename = "SDIOPath", default)]
    pub sdio_path: String,
    #[serde(rename = "NVCleanPath", default)]
    pub nvclean_path: String,
    #[serde(rename = "RAPRPath", default)]
    pub rapr_path: String,
    #[serde(rename = "JDownloaderPath", default)]
    pub jdownloader_path: String,
    #[serde(rename = "SteamPath", default)]
    pub steam_path: String,
    #[serde(rename = "SDIOScanTimeoutSec", default = "default_sdio_timeout")]
    pub sdio_scan_timeout_sec: u64,
    #[serde(rename = "DriverQueryTimeoutSec", default = "default_driver_timeout")]
    pub driver_query_timeout_sec: u64,
    #[serde(rename = "StaleOutputWarnSec", default = "default_stale_warn")]
    pub stale_output_warn_sec: u64,
    /// Pre-built NVCleanstall driver package exe (built via NVCleanstall's
    /// "Build Package" feature). When present, "Recommended Update" can run
    /// unattended instead of requiring the interactive GUI.
    #[serde(rename = "NVCleanPackagePath", default)]
    pub nvclean_package_path: String,
    /// Shell command used by "Open winutil". Defaults to Chris Titus Tech's
    /// WinUtil bootstrap one-liner.
    #[serde(rename = "WinutilCommand", default = "default_winutil_command")]
    pub winutil_command: String,
    /// UI language: "en" or "pt-BR". See `crate::i18n`.
    #[serde(rename = "Language", default = "default_language")]
    pub language: String,
    /// UI theme: "system" (follow the OS), "light" or "dark".
    /// See `crate::theme::ThemeChoice`.
    #[serde(rename = "Theme", default = "default_theme")]
    pub theme: String,
    /// Text-size multiplier applied as an egui zoom factor (1.0 = 100%).
    /// Clamped to 0.8..=2.0 on load; see `crate::theme::set_scale`.
    #[serde(rename = "UiScale", default = "default_ui_scale")]
    pub ui_scale: f32,

    /// Any keys present in settings.json that this struct doesn't model are
    /// preserved here and re-emitted verbatim on save.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

fn default_sdio_timeout() -> u64 {
    120
}
fn default_driver_timeout() -> u64 {
    30
}
fn default_stale_warn() -> u64 {
    120
}
fn default_winutil_command() -> String {
    DEFAULT_WINUTIL_COMMAND.to_string()
}
fn default_language() -> String {
    "en".to_string()
}
fn default_theme() -> String {
    "system".to_string()
}
fn default_ui_scale() -> f32 {
    1.0
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            sdio_path: String::new(),
            nvclean_path: String::new(),
            rapr_path: String::new(),
            jdownloader_path: String::new(),
            steam_path: String::new(),
            sdio_scan_timeout_sec: default_sdio_timeout(),
            driver_query_timeout_sec: default_driver_timeout(),
            stale_output_warn_sec: default_stale_warn(),
            nvclean_package_path: String::new(),
            winutil_command: default_winutil_command(),
            language: default_language(),
            theme: default_theme(),
            ui_scale: default_ui_scale(),
            extra: serde_json::Map::new(),
        }
    }
}

/// Resolve the "root" folder: the one containing `SystemUpdate_Topgrade.bat`.
/// Search order: walk upward from the exe's directory, then fall back to the
/// current working directory (and its ancestors).
pub fn resolve_root() -> Option<PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            for dir in exe_dir.ancestors() {
                if dir.join(BAT_NAME).is_file() {
                    return Some(dir.to_path_buf());
                }
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for dir in cwd.ancestors() {
            if dir.join(BAT_NAME).is_file() {
                return Some(dir.to_path_buf());
            }
        }
    }
    None
}

pub fn settings_path(root: &Path) -> PathBuf {
    root.join("settings.json")
}

/// Drop a leading UTF-8 byte-order mark.
///
/// The PowerShell dashboard saves this same file with `Set-Content -Encoding
/// UTF8`, and on Windows PowerShell 5.1 that writes a BOM. `serde_json`
/// rejects it outright ("expected value at line 1 column 1"), which used to
/// send `load_settings` down its `unwrap_or_default()` path -- so every
/// setting the PS dashboard had written was thrown away, and then overwritten
/// with defaults by the save in `DashboardApp::new`. Unknown keys held in
/// `extra` went with it.
fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

/// Load settings.json if present (degrading gracefully to defaults on any
/// parse error), then fill in any empty/dangling tool paths via simple
/// autodiscovery of common install locations.
pub fn load_settings(root: &Path) -> Settings {
    let path = settings_path(root);
    let mut settings = match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str::<Settings>(strip_bom(&text)).unwrap_or_default(),
        Err(_) => {
            // No settings.json yet: this is a first run. Default the text
            // size to Windows' own accessibility text-size setting instead
            // of always starting at 100%, so someone who has already told
            // Windows they want bigger text doesn't have to tell this app
            // too. A returning user's own choice (including an explicit
            // 100%) always overrides this once settings.json exists.
            let mut s = Settings::default();
            s.ui_scale = crate::theme::windows_text_scale();
            s
        }
    };

    autodiscover(root, &mut settings);
    settings
}

pub fn save_settings(root: &Path, settings: &Settings) -> std::io::Result<()> {
    let json = serde_json::to_string_pretty(settings).map_err(std::io::Error::other)?;
    std::fs::write(settings_path(root), json)
}

fn path_ok(p: &str) -> bool {
    !p.is_empty() && Path::new(p).exists()
}

/// Best-effort discovery of common tool install locations, mirroring
/// Functions.ps1's Get-AutoDiscoveredToolPaths. Only fills gaps; never
/// overwrites a value the user already configured (and that still exists).
fn autodiscover(root: &Path, settings: &mut Settings) {
    // Portable NVCleanstall dropped in by Get-NVCleanstall.ps1.
    if !path_ok(&settings.nvclean_path) {
        let c = root.join("tools").join("NVCleanstall.exe");
        if c.is_file() {
            settings.nvclean_path = c.to_string_lossy().to_string();
        }
    }
    let local_appdata = std::env::var("LOCALAPPDATA").unwrap_or_default();
    let program_files = std::env::var("ProgramFiles").unwrap_or_default();
    let program_files_x86 =
        std::env::var("ProgramFiles(x86)").unwrap_or_else(|_| program_files.clone());
    let winget_packages = Path::new(&local_appdata).join("Microsoft\\WinGet\\Packages");

    if !path_ok(&settings.sdio_path) {
        let mut candidates: Vec<PathBuf> = vec![
            PathBuf::from("C:\\SDIO"),
            Path::new(&program_files).join("SDIO"),
        ];
        if let Ok(entries) = std::fs::read_dir(&winget_packages) {
            for e in entries.flatten() {
                let name = e.file_name();
                let name = name.to_string_lossy();
                if name.starts_with("GlennDelahoy.SnappyDriverInstallerOrigin_") {
                    candidates.push(e.path());
                }
            }
        }
        for c in candidates {
            if c.is_dir() {
                let has_exe = std::fs::read_dir(&c).ok().is_some_and(|it| {
                    it.flatten().any(|e| {
                        let name = e.file_name();
                        Path::new(&name)
                            .extension()
                            .is_some_and(|x| x.eq_ignore_ascii_case("exe"))
                            && name.to_string_lossy().to_uppercase().starts_with("SDIO")
                    })
                });
                if has_exe {
                    settings.sdio_path = c.to_string_lossy().to_string();
                    break;
                }
            }
        }
    }

    if !path_ok(&settings.nvclean_path) {
        let candidates = vec![
            Path::new(&program_files).join("NVCleanstall\\NVCleanstall.exe"),
            Path::new(&program_files_x86).join("NVCleanstall\\NVCleanstall.exe"),
        ];
        for c in candidates {
            if c.is_file() {
                settings.nvclean_path = c.to_string_lossy().to_string();
                break;
            }
        }
    }

    if !path_ok(&settings.rapr_path) {
        let mut candidates = vec![Path::new(&program_files).join("Rapr\\Rapr.exe")];
        // winget portable install (lostindark.DriverStoreExplorer) drops
        // Rapr.exe into a versioned folder (sometimes one level deep).
        if let Ok(entries) = std::fs::read_dir(&winget_packages) {
            for e in entries.flatten() {
                let name = e.file_name();
                if name
                    .to_string_lossy()
                    .starts_with("lostindark.DriverStoreExplorer_")
                {
                    candidates.push(e.path().join("Rapr.exe"));
                    if let Ok(subs) = std::fs::read_dir(e.path()) {
                        for s in subs.flatten() {
                            if s.path().is_dir() {
                                candidates.push(s.path().join("Rapr.exe"));
                            }
                        }
                    }
                }
            }
        }
        for c in candidates {
            if c.is_file() {
                settings.rapr_path = c.to_string_lossy().to_string();
                break;
            }
        }
    }

    if !path_ok(&settings.jdownloader_path) {
        let candidates = vec![
            PathBuf::from("C:\\Program Files\\JDownloader"),
            PathBuf::from("C:\\Program Files (x86)\\JDownloader"),
            Path::new(&local_appdata).join("JDownloader 2.0"),
        ];
        for c in candidates {
            if c.join("JDownloader.jar").is_file() {
                settings.jdownloader_path = c.to_string_lossy().to_string();
                break;
            }
        }
    }

    if !path_ok(&settings.steam_path)
        && Path::new("C:\\Program Files (x86)\\Steam\\steam.exe").is_file()
    {
        settings.steam_path = "C:\\Program Files (x86)\\Steam".to_string();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_known_keys_and_preserves_unknown_ones() {
        let json = r#"{
            "SDIOPath": "C:\\SDIO",
            "SDIOScanTimeoutSec": 90,
            "SomeFutureKey": "kept-verbatim",
            "AnotherOne": 42
        }"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.sdio_path, "C:\\SDIO");
        assert_eq!(settings.sdio_scan_timeout_sec, 90);
        // Keys not present in this JSON fall back to their defaults...
        assert_eq!(settings.driver_query_timeout_sec, 30);
        assert_eq!(settings.winutil_command, DEFAULT_WINUTIL_COMMAND);
        // ...and unknown keys preserved for round-tripping.
        assert_eq!(
            settings.extra.get("SomeFutureKey").and_then(|v| v.as_str()),
            Some("kept-verbatim")
        );
        assert_eq!(
            settings.extra.get("AnotherOne").and_then(|v| v.as_i64()),
            Some(42)
        );

        let serialized = serde_json::to_string(&settings).unwrap();
        let roundtripped: Settings = serde_json::from_str(&serialized).unwrap();
        assert_eq!(roundtripped.sdio_path, "C:\\SDIO");
        assert_eq!(
            roundtripped
                .extra
                .get("SomeFutureKey")
                .and_then(|v| v.as_str()),
            Some("kept-verbatim")
        );
    }

    #[test]
    fn missing_file_yields_defaults() {
        let settings = Settings::default();
        assert_eq!(settings.sdio_scan_timeout_sec, 120);
        assert_eq!(settings.driver_query_timeout_sec, 30);
        assert_eq!(settings.stale_output_warn_sec, 120);
        assert_eq!(settings.winutil_command, DEFAULT_WINUTIL_COMMAND);
        assert!(settings.nvclean_package_path.is_empty());
        assert_eq!(settings.language, "en");
        assert_eq!(settings.theme, "system");
        assert_eq!(settings.ui_scale, 1.0);
    }

    #[test]
    fn ui_scale_defaults_and_round_trips() {
        let settings: Settings = serde_json::from_str(r#"{"SDIOPath": "C:\\SDIO"}"#).unwrap();
        assert_eq!(settings.ui_scale, 1.0);

        let settings: Settings = serde_json::from_str(r#"{"UiScale": 1.3}"#).unwrap();
        assert_eq!(settings.ui_scale, 1.3);
        let roundtripped: Settings =
            serde_json::from_str(&serde_json::to_string(&settings).unwrap()).unwrap();
        assert_eq!(roundtripped.ui_scale, 1.3);
    }

    /// The PowerShell dashboard writes this file with a UTF-8 BOM. Losing
    /// every setting (and every unknown key) to a silent parse failure is the
    /// worst outcome here, so guard it directly.
    #[test]
    fn bom_prefixed_settings_still_parse() {
        let json = "\u{feff}{\"SDIOScanTimeoutSec\": 999, \"Language\": \"pt-BR\", \"Custom\": 1}";
        let settings: Settings = serde_json::from_str(strip_bom(json)).unwrap();
        assert_eq!(settings.sdio_scan_timeout_sec, 999);
        assert_eq!(settings.language, "pt-BR");
        assert_eq!(settings.extra.get("Custom").and_then(|v| v.as_i64()), Some(1));
    }

    /// End-to-end through `load_settings`, which is where the loss happened:
    /// the parse failed, `unwrap_or_default()` swallowed it, and
    /// `DashboardApp::new` then saved the defaults over the user's file.
    #[test]
    fn load_settings_reads_a_bom_prefixed_file_from_disk() {
        let dir = std::env::temp_dir().join(format!(
            "upkeep-bom-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let body = r#"{"SDIOScanTimeoutSec": 999, "Language": "pt-BR", "SomeFutureKey": "kept"}"#;
        // Exactly what PowerShell 5.1's `Set-Content -Encoding UTF8` writes.
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(body.as_bytes());
        std::fs::write(dir.join("settings.json"), &bytes).unwrap();

        let loaded = load_settings(&dir);
        assert_eq!(loaded.sdio_scan_timeout_sec, 999);
        assert_eq!(loaded.language, "pt-BR");
        assert_eq!(
            loaded.extra.get("SomeFutureKey").and_then(|v| v.as_str()),
            Some("kept"),
            "unknown keys from the PowerShell dashboard must survive"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn strip_bom_leaves_clean_json_untouched() {
        assert_eq!(strip_bom("{\"a\":1}"), "{\"a\":1}");
        assert_eq!(strip_bom("\u{feff}{\"a\":1}"), "{\"a\":1}");
    }

    #[test]
    fn theme_key_defaults_to_system_and_round_trips() {
        let json = r#"{"SDIOPath": "C:\\SDIO"}"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.theme, "system");

        let json = r#"{"Theme": "light"}"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.theme, "light");

        let serialized = serde_json::to_string(&settings).unwrap();
        let roundtripped: Settings = serde_json::from_str(&serialized).unwrap();
        assert_eq!(roundtripped.theme, "light");
    }

    #[test]
    fn language_key_defaults_to_en_and_round_trips_pt_br() {
        let json = r#"{"SDIOPath": "C:\\SDIO"}"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.language, "en");

        let json = r#"{"Language": "pt-BR"}"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.language, "pt-BR");

        let serialized = serde_json::to_string(&settings).unwrap();
        let roundtripped: Settings = serde_json::from_str(&serialized).unwrap();
        assert_eq!(roundtripped.language, "pt-BR");
    }
}
