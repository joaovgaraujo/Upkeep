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

#[derive(Debug, Clone, Default)]
pub struct UpdatePlan {
    pub items: Vec<UpdateItem>,
    pub windows: bool,
    pub feature: bool,
    pub store: bool,
    pub steam: bool,
    pub other_apps: bool,
    pub loading: bool,
    pub error: Option<String>,
    pub only_ids: Option<Vec<String>>,
    pub review_categories: Option<[bool; 5]>,
    /// Claude Code / Codex CLI installs found before the run, with the
    /// install method the user wants each one updated through.
    pub ai_cli: Vec<AiCliTool>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AiCliInstall {
    pub method: String,
    pub version: String,
}

/// One AI coding CLI as `Update-AiClis.ps1 -Detect` reports it.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AiCliTool {
    pub key: String,
    pub name: String,
    pub winget_id: String,
    pub installs: Vec<AiCliInstall>,
    /// Method -> newest version that method offers.
    #[serde(default)]
    pub latest: std::collections::BTreeMap<String, String>,
    /// Methods this PC can install through.
    #[serde(default)]
    pub targets: Vec<String>,
    /// Saved preference: "" keeps the current method.
    #[serde(default)]
    pub preferred: String,
}

impl AiCliTool {
    /// The run changes something only while the preferred method is not the
    /// sole install (it gets installed, or the other installs removed).
    pub fn switch_pending(&self) -> bool {
        !self.preferred.is_empty() && self.installs.iter().any(|i| i.method != self.preferred)
    }

    /// A method offering a newer version than every current install, with
    /// that version. Used to point out that switching would help.
    pub fn newer_method(&self) -> Option<(String, String)> {
        let best_installed = self
            .installs
            .iter()
            .filter_map(|i| parse_version(&i.version))
            .max()?;
        self.targets
            .iter()
            .filter(|m| !self.installs.iter().any(|i| &i.method == *m))
            .filter_map(|m| {
                let v = self.latest.get(m)?;
                (parse_version(v)? > best_installed).then(|| (m.clone(), v.clone()))
            })
            .max_by(|a, b| parse_version(&a.1).cmp(&parse_version(&b.1)))
    }
}

/// Display name for an install method; "" means keep the current one.
pub fn method_label(method: &str, pt: bool) -> &'static str {
    match (method, pt) {
        ("npm", _) => "npm",
        ("native", true) => "instalador próprio",
        ("native", false) => "own installer",
        ("winget", _) => "WinGet",
        (_, true) => "manter como está",
        (_, false) => "keep as is",
    }
}

fn parse_version(text: &str) -> Option<Vec<u64>> {
    let parts: Vec<u64> = text
        .split('.')
        .map(|p| p.trim().parse::<u64>())
        .collect::<Result<_, _>>()
        .ok()?;
    (!parts.is_empty()).then_some(parts)
}

impl UpdatePlan {
    pub fn selected_ids(&self) -> Vec<String> {
        self.items
            .iter()
            .filter(|item| item.selected)
            .map(|item| item.id.clone())
            .collect()
    }
    pub fn can_confirm(&self) -> bool {
        !self.loading
            && self.error.is_none()
            && (self.items.iter().any(|item| item.selected)
                || self.ai_cli.iter().any(|tool| tool.switch_pending())
                || self.windows
                || self.feature
                || self.store
                || self.steam
                || self.other_apps)
    }
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

/// Claude Code / Codex CLI installs and the methods they could move to.
pub fn ai_cli_channels(root: &Path) -> Result<Vec<AiCliTool>, String> {
    let script = root.join("steps/Update-AiClis.ps1");
    let text = crate::system::run_hidden(
        "powershell.exe",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            &script.to_string_lossy(),
            "-Detect",
        ],
        Duration::from_secs(120),
    )?;
    let json = text.trim_start_matches('\u{feff}').trim();
    // PowerShell 5.1 can print a one-element array as the bare object.
    serde_json::from_str::<Vec<AiCliTool>>(json)
        .or_else(|_| serde_json::from_str::<AiCliTool>(json).map(|t| vec![t]))
        .map_err(|e| format!("Could not read AI CLI installs: {e}. {text}"))
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

pub fn load_failed() -> Result<Vec<String>, String> {
    let path = ignore_path()
        .parent()
        .unwrap()
        .join("Reports/winget-failed.json");
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("Could not read failed-app report: {e}"))?;
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
    fn confirmation_blocks_loading_errors_and_empty_selections() {
        let mut plan = super::UpdatePlan::default();
        assert!(!plan.can_confirm());
        plan.store = true;
        assert!(plan.can_confirm());
        plan.loading = true;
        assert!(!plan.can_confirm());
        plan.loading = false;
        plan.error = Some("Inventory failed".into());
        assert!(!plan.can_confirm());
    }

    #[test]
    fn confirmation_uses_only_checked_ids_and_other_providers_are_opt_in() {
        let item = |id: &str, selected| super::UpdateItem {
            id: id.into(),
            name: id.into(),
            current: "1".into(),
            available: "2".into(),
            selected,
        };
        let plan = super::UpdatePlan {
            items: vec![
                item("Example.Checked", true),
                item("Example.Unchecked", false),
            ],
            ..Default::default()
        };
        assert!(plan.can_confirm());
        assert_eq!(plan.selected_ids(), vec!["Example.Checked"]);
        assert!(!plan.other_apps);
    }
    fn tool(installs: &[(&str, &str)], preferred: &str) -> super::AiCliTool {
        super::AiCliTool {
            key: "claude-code".into(),
            name: "Claude Code".into(),
            winget_id: "Anthropic.ClaudeCode".into(),
            installs: installs
                .iter()
                .map(|(m, v)| super::AiCliInstall {
                    method: (*m).into(),
                    version: (*v).into(),
                })
                .collect(),
            latest: [
                ("npm", "2.1.317"),
                ("native", "2.1.317"),
                ("winget", "2.1.302"),
            ]
            .into_iter()
            .map(|(m, v)| (m.to_string(), v.to_string()))
            .collect(),
            targets: vec!["npm".into(), "native".into(), "winget".into()],
            preferred: preferred.into(),
        }
    }

    #[test]
    fn a_lagging_winget_install_points_at_the_newer_method() {
        let t = tool(&[("winget", "2.1.302")], "");
        assert_eq!(
            t.newer_method().map(|(_, v)| v),
            Some("2.1.317".to_string())
        );
        assert!(!t.switch_pending());
        assert!(tool(&[("npm", "2.1.317")], "").newer_method().is_none());
    }

    #[test]
    fn a_chosen_method_is_a_switch_only_until_it_is_the_sole_install() {
        assert!(tool(&[("winget", "2.1.302")], "npm").switch_pending());
        assert!(tool(&[("npm", "2.1.317"), ("winget", "2.1.302")], "npm").switch_pending());
        assert!(!tool(&[("npm", "2.1.317")], "npm").switch_pending());
        let plan = super::UpdatePlan {
            ai_cli: vec![tool(&[("winget", "2.1.302")], "npm")],
            ..Default::default()
        };
        assert!(plan.can_confirm());
    }

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
