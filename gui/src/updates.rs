use std::{path::Path, time::Duration};

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct UpdateItem {
    pub id: String,
    pub name: String,
    pub current: String,
    pub available: String,
    #[serde(default)]
    pub selected: bool,
}

pub fn inventory(root: &Path) -> Result<Vec<UpdateItem>, String> {
    let script = root.join("steps/Update-WingetApps.ps1");
    let text = crate::system::run_hidden(
        "powershell.exe",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            &script.to_string_lossy(),
            "-InventoryOnly",
        ],
        Duration::from_secs(180),
    )?;
    serde_json::from_str(text.trim_start_matches('\u{feff}').trim())
        .map_err(|e| format!("Could not read update inventory: {e}. {text}"))
}

fn ignore_path() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap_or_default())
        .join("Upkeep/winget-ignore.json")
}

pub fn load_ignored() -> Result<Vec<String>, String> {
    let path = ignore_path();
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(text.trim_start_matches('\u{feff}')).map_err(|e| e.to_string())
}

pub fn save_ignored(ids: &[String]) -> Result<(), String> {
    let path = ignore_path();
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(path, serde_json::to_vec_pretty(ids).unwrap()).map_err(|e| e.to_string())
}

/// Keep evidence of success alongside actionable failures in mixed runs.
pub fn result_details<'a>(lines: impl Iterator<Item = &'a String>) -> Vec<String> {
    let mut details = Vec::new();
    for line in lines {
        let lower = line.to_lowercase();
        let detail = if lower.contains("0x80073d02") {
            format!("{line} Close this app and retry Store updates; other successful updates were kept.")
        } else if lower.contains("different install technology") {
            format!("{line} Installer type changed: this app needs a manual migration. Other apps can still update.")
        } else if lower.starts_with("[result]")
            || (lower.starts_with("[winget]")
                && (lower.contains("upgraded")
                    || lower.contains(" : ")
                    || lower.contains("all pending")))
            || (lower.starts_with("[store]")
                && (lower.contains("failed") || lower.contains("done.")))
            || (lower.starts_with("[clients]")
                && (lower.contains(": ok") || lower.contains(": error")))
            || lower.starts_with("[error]")
            || lower.starts_with("[timeout]")
        {
            line.clone()
        } else {
            continue;
        };
        if !details.contains(&detail) {
            details.push(detail);
        }
    }
    details
}

#[cfg(test)]
mod tests {
    #[test]
    fn mixed_results_keep_success_and_actionable_failure() {
        let lines = [
            "[winget] Upgraded 3 package(s): A, B, C".into(),
            "[store] WhatsApp: failed (0x80073D02)".into(),
        ];
        let result = super::result_details(lines.iter());
        assert_eq!(result.len(), 2);
        assert!(result[0].contains("Upgraded 3"));
        assert!(result[1].contains("Close this app"));
    }
}
