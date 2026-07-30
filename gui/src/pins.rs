//! Pin list editor logic: parses `winget pin add` / `choco pin add` lines out
//! of the engine .bat file, validates new entries, and rewrites just the pin
//! section on save (mirrors Functions.ps1's Get-PinListFromBat /
//! Set-PinListInBat).

use regex::Regex;
use std::path::Path;
use std::sync::LazyLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Manager {
    Winget,
    Choco,
}

impl Manager {
    pub fn as_str(self) -> &'static str {
        match self {
            Manager::Winget => "winget",
            Manager::Choco => "choco",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinEntry {
    pub id: String,
    pub manager: Manager,
}

static WINGET_PIN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*winget\s+pin\s+add\s+--id\s+(\S+)").unwrap());
static CHOCO_PIN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*choco\s+pin\s+add\s+(?:-n|--name)=(\S+)").unwrap());

pub fn parse_pins(bat_text: &str) -> Vec<PinEntry> {
    let mut out = Vec::new();
    for line in bat_text.lines() {
        if let Some(c) = WINGET_PIN_RE.captures(line) {
            out.push(PinEntry {
                id: c[1].to_string(),
                manager: Manager::Winget,
            });
        } else if let Some(c) = CHOCO_PIN_RE.captures(line) {
            out.push(PinEntry {
                id: c[1].to_string(),
                manager: Manager::Choco,
            });
        }
    }
    out
}

/// Validates a candidate pin id: non-empty, no whitespace, format match for
/// the target manager, and not already present.
pub fn validate_pin_id(id: &str, manager: Manager, existing: &[PinEntry]) -> Result<(), String> {
    if id.trim().is_empty() {
        return Err("Pin ID cannot be empty".to_string());
    }
    if id.chars().any(char::is_whitespace) {
        return Err("Pin ID cannot contain whitespace".to_string());
    }

    // These have to accept every id the Pins page actually LISTS, or the user
    // clicks Add on a row the app itself rendered and gets a format error.
    // Real ids that the stricter patterns rejected:
    //   winget  Notepad++.Notepad++   (`+`)
    //   choco   git.install, nodejs.install, python.install   (`.`)
    // `+` and `.` are the only additions; whitespace is already rejected
    // above, and `\w` keeps out the shell metacharacters that matter, since
    // these ids are written into the .bat as `winget pin add --id <id>`.
    static WINGET_ID_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^\w[\w\-\+]*(\.[\w\-\+]+)+$").unwrap());
    static CHOCO_ID_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^\w[\w\-\+]*(\.[\w\-\+]+)*$").unwrap());
    let ok = match manager {
        Manager::Winget => WINGET_ID_RE.is_match(id),
        Manager::Choco => CHOCO_ID_RE.is_match(id),
    };
    if !ok {
        return Err(format!(
            "Pin ID does not match expected format for {}",
            manager.as_str()
        ));
    }

    if existing.iter().any(|p| p.id == id && p.manager == manager) {
        return Err(format!("Pin ID already exists for {}", manager.as_str()));
    }

    Ok(())
}

/// Rewrites only the pin section of the bat file (from `echo [pins]` through
/// the next `rem -- <Section>` header that isn't itself pin-related),
/// preserving everything else. Writes a `.bak` backup of the previous
/// content first.
pub fn write_pins(bat_path: &Path, pins: &[PinEntry]) -> Result<(), String> {
    let content =
        std::fs::read_to_string(bat_path).map_err(|e| format!("Could not read bat file: {e}"))?;

    static HEADER_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)^\s*echo\s+\[pins\]").unwrap());
    static SECTION_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)^rem\s+--\s+\w").unwrap());
    static PIN_WORD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)pin").unwrap());

    let lines: Vec<&str> = content.lines().collect();

    let start = lines
        .iter()
        .position(|l| HEADER_RE.is_match(l))
        .ok_or_else(|| "Could not find pin section (echo [pins]) in batch file".to_string())?;

    let mut end = lines.len();
    for (i, l) in lines.iter().enumerate().skip(start + 1) {
        if SECTION_RE.is_match(l) && !PIN_WORD_RE.is_match(l) {
            end = i;
            break;
        }
    }

    let winget_pins: Vec<&PinEntry> = pins
        .iter()
        .filter(|p| p.manager == Manager::Winget)
        .collect();
    let choco_pins: Vec<&PinEntry> = pins
        .iter()
        .filter(|p| p.manager == Manager::Choco)
        .collect();

    let mut new_lines: Vec<String> = Vec::new();
    new_lines.push("echo [pins] Pinning packages in winget and chocolatey...".to_string());

    if !winget_pins.is_empty() {
        new_lines.push("where winget >nul 2>&1 && (".to_string());
        for pin in &winget_pins {
            new_lines.push(format!(
                "    winget pin add --id {} --accept-source-agreements >nul 2>&1",
                pin.id
            ));
        }
        new_lines.push(")".to_string());
    }

    if !choco_pins.is_empty() {
        new_lines.push("where choco >nul 2>&1 && (".to_string());
        for pin in &choco_pins {
            new_lines.push(format!(
                "    choco pin add -n={}              >nul 2>&1",
                pin.id
            ));
        }
        new_lines.push(")".to_string());
    }

    new_lines.push(String::new());

    let mut result: Vec<String> = Vec::new();
    result.extend(lines[..start].iter().map(std::string::ToString::to_string));
    result.extend(new_lines);
    result.extend(lines[end..].iter().map(std::string::ToString::to_string));

    // Backup before writing.
    let backup_path = {
        let mut p = bat_path.as_os_str().to_os_string();
        p.push(".bak");
        std::path::PathBuf::from(p)
    };
    std::fs::write(&backup_path, &content)
        .map_err(|e| format!("Could not write backup file: {e}"))?;

    let new_content = result.join("\r\n") + "\r\n";
    std::fs::write(bat_path, new_content).map_err(|e| format!("Could not write bat file: {e}"))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_winget_and_choco_pins() {
        let text = "\
@echo off
where winget >nul 2>&1 && (
    winget pin add --id Adobe.Acrobat.Reader.64-bit --accept-source-agreements >nul 2>&1
    winget pin add --id MiKTeX.MiKTeX              --accept-source-agreements >nul 2>&1
)
where choco >nul 2>&1 && (
    choco pin add -n=adobereader              >nul 2>&1
    choco pin add --name=adobeair             >nul 2>&1
)
";
        let pins = parse_pins(text);
        assert_eq!(pins.len(), 4);
        assert_eq!(pins[0].id, "Adobe.Acrobat.Reader.64-bit");
        assert_eq!(pins[0].manager, Manager::Winget);
        assert_eq!(pins[2].id, "adobereader");
        assert_eq!(pins[2].manager, Manager::Choco);
        assert_eq!(pins[3].id, "adobeair");
    }

    #[test]
    fn validates_winget_id_format() {
        let existing = vec![];
        assert!(validate_pin_id("Adobe.Acrobat.Reader.64-bit", Manager::Winget, &existing).is_ok());
        assert!(validate_pin_id("notadotted", Manager::Winget, &existing).is_err());
        assert!(validate_pin_id("", Manager::Winget, &existing).is_err());
        assert!(validate_pin_id("has space.x", Manager::Winget, &existing).is_err());
    }

    #[test]
    fn validates_choco_id_format() {
        let existing = vec![];
        assert!(validate_pin_id("adobereader", Manager::Choco, &existing).is_ok());
        // Dotted choco ids are extremely common and ARE listed by the Pins
        // page, so rejecting them made the Add button fail on rows the app
        // had just drawn.
        assert!(validate_pin_id("git.install", Manager::Choco, &existing).is_ok());
        assert!(validate_pin_id("nodejs.install", Manager::Choco, &existing).is_ok());
        assert!(validate_pin_id("adobe.reader", Manager::Choco, &existing).is_ok());
        assert!(validate_pin_id("has space", Manager::Choco, &existing).is_err());
        assert!(validate_pin_id(".leadingdot", Manager::Choco, &existing).is_err());
        assert!(validate_pin_id("", Manager::Choco, &existing).is_err());
    }

    /// Every id the Pins page can list must be pinnable. Regression guard for
    /// the picker offering rows whose Add button then errored.
    #[test]
    fn accepts_the_ids_the_pins_page_actually_lists() {
        let existing = vec![];
        for id in ["Notepad++.Notepad++", "Adobe.Acrobat.Reader.64-bit", "7zip.7zip"] {
            assert!(
                validate_pin_id(id, Manager::Winget, &existing).is_ok(),
                "winget id {id} was listed but rejected"
            );
        }
        for id in ["git.install", "python.install", "vcredist140", "7zip.install"] {
            assert!(
                validate_pin_id(id, Manager::Choco, &existing).is_ok(),
                "choco id {id} was listed but rejected"
            );
        }
    }

    #[test]
    fn rejects_duplicate_pin() {
        let existing = vec![PinEntry {
            id: "adobereader".to_string(),
            manager: Manager::Choco,
        }];
        let result = validate_pin_id("adobereader", Manager::Choco, &existing);
        assert!(result.is_err());
    }

    #[test]
    fn round_trip_against_real_bat_file() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let bat_path = repo_root.join("SystemUpdate_Topgrade.bat");
        if !bat_path.is_file() {
            // Not running inside the full repo checkout; skip.
            return;
        }

        let tmp = std::env::temp_dir().join("updateall_pins_roundtrip_test.bat");
        std::fs::copy(&bat_path, &tmp).unwrap();

        let original_text = std::fs::read_to_string(&tmp).unwrap();
        let original_pins = parse_pins(&original_text);
        assert!(
            !original_pins.is_empty(),
            "expected the real bat to have pins"
        );

        // Add one pin, save, and confirm it round-trips.
        let mut pins = original_pins.clone();
        pins.push(PinEntry {
            id: "Test.Vendor.Package".to_string(),
            manager: Manager::Winget,
        });
        write_pins(&tmp, &pins).expect("write_pins should succeed");

        let backup = std::fs::read_to_string(format!("{}.bak", tmp.display())).unwrap();
        assert_eq!(
            backup, original_text,
            "backup should match pre-save content"
        );

        let new_text = std::fs::read_to_string(&tmp).unwrap();
        let new_pins = parse_pins(&new_text);
        assert_eq!(new_pins.len(), original_pins.len() + 1);
        assert!(new_pins.iter().any(|p| p.id == "Test.Vendor.Package"));

        // The section before/after the pin block must be untouched.
        assert!(new_text.contains("rem -- Prevent Discord from adding itself to Windows startup"));
        assert!(new_text.contains(
            "rem -- Ensure PSWindowsUpdate is installed (topgrade uses it) ----------------"
        ));

        let _ = std::fs::remove_file(&tmp);
        let _ = std::fs::remove_file(format!("{}.bak", tmp.display()));
    }
}
