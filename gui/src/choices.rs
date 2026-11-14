//! What you turned off on the Startup & Services page, kept across updates.
//!
//! App updates turn their own startup items back on: on 2026-11-13 a winget
//! update of Tailscale set its service back to Automatic and re-created its
//! Startup-folder shortcut, and the RustDesk installer added a new one. Every
//! change made on the page is recorded in
//! `%LOCALAPPDATA%\Upkeep\startup-choices.json`; after each update run the
//! engine (`steps\Restore-StartupChoices.ps1`) puts back anything an update
//! turned on again. Turning an item back on removes it from the file.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::system::{StartupEntry, TaskEntry};

/// A startup item kept off, by its StartupApproved value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartupChoice {
    pub name: String,
    pub approved_key: String,
    pub approved_name: String,
}

/// A scheduled task kept disabled.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskChoice {
    pub path: String,
    pub name: String,
}

/// A service kept at a start type (Manual or Disabled).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceChoice {
    pub name: String,
    pub start_mode: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Choices {
    #[serde(default)]
    pub startup: Vec<StartupChoice>,
    #[serde(default)]
    pub tasks: Vec<TaskChoice>,
    #[serde(default)]
    pub services: Vec<ServiceChoice>,
}

impl Choices {
    pub fn default_path() -> Option<PathBuf> {
        let local = std::env::var_os("LOCALAPPDATA")?;
        Some(
            Path::new(&local)
                .join("Upkeep")
                .join("startup-choices.json"),
        )
    }

    /// A missing or unreadable file is an empty set of choices.
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(t.trim_start_matches('\u{feff}')).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    pub fn is_empty(&self) -> bool {
        self.startup.is_empty() && self.tasks.is_empty() && self.services.is_empty()
    }

    pub fn set_startup(&mut self, entry: &StartupEntry, enabled: bool) {
        self.startup.retain(|c| {
            !(c.approved_key.eq_ignore_ascii_case(&entry.approved_key)
                && c.approved_name.eq_ignore_ascii_case(&entry.approved_name))
        });
        if !enabled && entry.can_toggle() {
            self.startup.push(StartupChoice {
                name: entry.name.clone(),
                approved_key: entry.approved_key.clone(),
                approved_name: entry.approved_name.clone(),
            });
        }
    }

    pub fn set_task(&mut self, entry: &TaskEntry, enabled: bool) {
        self.tasks.retain(|c| {
            !(c.path.eq_ignore_ascii_case(&entry.path) && c.name.eq_ignore_ascii_case(&entry.name))
        });
        if !enabled {
            self.tasks.push(TaskChoice {
                path: entry.path.clone(),
                name: entry.name.clone(),
            });
        }
    }

    /// Automatic is the usual default, so choosing it just forgets the
    /// service; Manual and Disabled are kept.
    pub fn set_service(&mut self, name: &str, start_mode: &str) {
        self.services.retain(|c| !c.name.eq_ignore_ascii_case(name));
        if matches!(start_mode, "Manual" | "Disabled") {
            self.services.push(ServiceChoice {
                name: name.to_string(),
                start_mode: start_mode.to_string(),
            });
        }
    }

    pub fn keeps_startup(&self, entry: &StartupEntry) -> bool {
        self.startup.iter().any(|c| {
            c.approved_key.eq_ignore_ascii_case(&entry.approved_key)
                && c.approved_name.eq_ignore_ascii_case(&entry.approved_name)
        })
    }

    pub fn keeps_task(&self, entry: &TaskEntry) -> bool {
        self.tasks.iter().any(|c| {
            c.path.eq_ignore_ascii_case(&entry.path) && c.name.eq_ignore_ascii_case(&entry.name)
        })
    }

    pub fn keeps_service(&self, name: &str) -> bool {
        self.services
            .iter()
            .any(|c| c.name.eq_ignore_ascii_case(name))
    }
}

/// Loads, changes and saves the default file in one go. Errors are returned
/// for the caller to show; the change itself has already been made.
pub fn update(change: impl FnOnce(&mut Choices)) -> Result<(), String> {
    let path = Choices::default_path().ok_or("LOCALAPPDATA is not set")?;
    let mut c = Choices::load(&path);
    change(&mut c);
    c.save(&path)
        .map_err(|e| format!("could not save {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn startup(name: &str) -> StartupEntry {
        StartupEntry {
            location: "HKCU:\\...\\Run".into(),
            name: name.into(),
            command: "x.exe".into(),
            approved_key: "HKCU:\\...\\StartupApproved\\Run".into(),
            approved_name: name.into(),
            enabled: true,
        }
    }

    fn task(name: &str) -> TaskEntry {
        TaskEntry {
            path: "\\".into(),
            name: name.into(),
            state: "Ready".into(),
            command: String::new(),
            description: String::new(),
            when: Vec::new(),
        }
    }

    #[test]
    fn records_off_and_forgets_on() {
        let mut c = Choices::default();
        c.set_startup(&startup("Tool"), false);
        c.set_startup(&startup("Tool"), false);
        assert_eq!(c.startup.len(), 1, "no duplicates");
        assert!(c.keeps_startup(&startup("Tool")));
        c.set_startup(&startup("Tool"), true);
        assert!(c.startup.is_empty());

        c.set_task(&task("Updater"), false);
        assert!(c.keeps_task(&task("Updater")));
        c.set_task(&task("Updater"), true);
        assert!(c.tasks.is_empty());

        c.set_service("Tailscale", "Manual");
        assert!(c.keeps_service("tailscale"));
        c.set_service("Tailscale", "Automatic");
        assert!(c.is_empty());
    }

    #[test]
    fn round_trips_through_a_file_and_tolerates_a_bom() {
        let dir = std::env::temp_dir().join(format!("upkeep-choices-{}", std::process::id()));
        let path = dir.join("startup-choices.json");
        let mut c = Choices::default();
        c.set_startup(&startup("Tool"), false);
        c.set_task(&task("Updater"), false);
        c.set_service("SQLBrowser", "Disabled");
        c.save(&path).unwrap();
        assert_eq!(Choices::load(&path), c);
        // Windows PowerShell 5.1 writes a BOM if the engine ever rewrites it.
        let text = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, format!("\u{feff}{text}")).unwrap();
        assert_eq!(Choices::load(&path), c);
        assert!(Choices::load(&dir.join("missing.json")).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
