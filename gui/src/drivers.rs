//! Driver store query: runs `pnputil /enum-drivers` hidden with a timeout and
//! parses its text output (port of Functions.ps1's ConvertFrom-PnpUtilOutput).

use crate::system::{kill_tree, wait_bounded, KILL_GRACE};
use regex::Regex;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{mpsc, LazyLock};
use std::thread;
use std::time::Duration;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, Clone)]
pub struct DriverEntry {
    pub published_name: String,
    pub class_name: String,
    pub driver_version: String,
    pub driver_date: String,
}

/// Why `pnputil /enum-drivers` produced no usable output. A dedicated enum
/// instead of a `timed_out` flag plus a `-1` exit-code sentinel: "killed by
/// the watchdog", "failed to spawn/wait" and "exited with a bad code" are
/// different facts and the type system should keep them apart.
#[derive(Debug)]
pub enum PnpUtilError {
    /// The process could not be spawned or waited on.
    Io(std::io::Error),
    /// Still running after the timeout; killed by the watchdog.
    TimedOut,
    /// Exited with a non-zero status (`None` if the OS reported no code).
    Failed(Option<i32>),
}

/// Runs `pnputil /enum-drivers` hidden and returns its stdout, killing the
/// process if it outlives `timeout`. Stdout is read on a helper thread so a
/// large driver list can't deadlock the pipe; that thread's channel send
/// doubles as the completion signal (the pipe closes when pnputil exits),
/// so the timeout needs no polling loop.
pub fn run_pnputil(timeout: Duration) -> Result<String, PnpUtilError> {
    let mut cmd = Command::new("pnputil");
    cmd.arg("/enum-drivers")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = cmd.spawn().map_err(PnpUtilError::Io)?;
    let mut stdout = child
        .stdout
        .take()
        .expect("stdout is piped in the Command above");

    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        let _ = tx.send(buf);
    });

    let Ok(buf) = rx.recv_timeout(timeout) else {
        kill_tree(&mut child);
        wait_bounded(&mut child, KILL_GRACE);
        return Err(PnpUtilError::TimedOut);
    };

    // Bounded, and kills the tree if pnputil won't exit -- see
    // `system::wait_bounded`. An unbounded wait here wedged the Driver Store
    // tab's spinner for the rest of the session.
    let Some(status) = wait_bounded(&mut child, KILL_GRACE) else {
        kill_tree(&mut child);
        wait_bounded(&mut child, KILL_GRACE);
        return Err(PnpUtilError::TimedOut);
    };
    if status.success() {
        Ok(String::from_utf8_lossy(&buf).into_owned())
    } else {
        Err(PnpUtilError::Failed(status.code()))
    }
}

static PUBLISHED_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*Published Name\s*:\s*(.+?)\s*$").unwrap());
static CLASS_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*Class Name\s*:\s*(.+?)\s*$").unwrap());
static VERSION_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*Driver Version\s*:\s*(.+?)\s*$").unwrap());
static VERSION_SPLIT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(\d{1,2}/\d{1,2}/\d{4})\s+(.+?)\s*$").unwrap());

// -- Locale-independent fallbacks -----------------------------------------
//
// pnputil TRANSLATES its labels: "Nome Publicado:" on pt-BR, "Veröffentlichter
// Name:" on de-DE. Matching on the English label alone meant every
// non-English Windows parsed to zero drivers and showed an empty tab with no
// error, because the process itself had exited successfully.
//
// The VALUES keep their shape in every locale, so they are what we key off
// when the English labels aren't there. NOTE: the `regex` crate has no
// lookahead/lookbehind, so these are all plain anchored patterns.

/// A published driver name is always an OEM inf. Anchored, so the block's
/// `Original Name: nvhda.inf` can't be mistaken for it.
static OEM_INF_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^oem\d+\.inf$").unwrap());
/// Class GUID is shape-stable; the class NAME is the line above it.
static CLASS_GUID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$").unwrap());
/// `<date> <dotted version>`, with the separator and field order both
/// localized (06/13/2025 en-US, 13/06/2025 pt-BR, 13.06.2025 de-DE). The date
/// is display-only, so it is kept verbatim rather than disambiguated.
static VERSION_VALUE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(\d{1,2}[-/.]\d{1,2}[-/.]\d{4})\s+(\d+(?:\.\d+){1,3})$").unwrap()
});

/// The value half of a `Label: value` line, in any language.
fn label_value(line: &str) -> &str {
    line.split_once(':')
        .map(|(_, v)| v.trim())
        .unwrap_or_else(|| line.trim())
}

pub fn parse_pnputil_output(text: &str) -> Vec<DriverEntry> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    let normalized = text.replace("\r\n", "\n");

    // Split into blocks separated by blank (or whitespace-only) lines.
    let mut blocks: Vec<Vec<&str>> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    for line in normalized.lines() {
        if line.trim().is_empty() {
            if !current.is_empty() {
                blocks.push(std::mem::take(&mut current));
            }
        } else {
            current.push(line);
        }
    }
    if !current.is_empty() {
        blocks.push(current);
    }

    let mut drivers = Vec::new();
    for block in blocks {
        // Gate on the VALUE, not an English label: a driver block is one
        // that names an OEM inf.
        if !block.iter().any(|l| OEM_INF_RE.is_match(label_value(l))) {
            continue;
        }

        let mut published_name = None;
        let mut class_name = String::new();
        let mut driver_version = String::new();
        let mut driver_date = String::new();

        // Pass 1: the English labels, when present. Exact and unambiguous.
        for line in &block {
            if let Some(c) = PUBLISHED_RE.captures(line) {
                published_name = Some(c[1].to_string());
            } else if let Some(c) = CLASS_RE.captures(line) {
                class_name = c[1].to_string();
            } else if let Some(c) = VERSION_RE.captures(line) {
                let full = c[1].to_string();
                if let Some(vc) = VERSION_SPLIT_RE.captures(&full) {
                    driver_date = vc[1].to_string();
                    driver_version = vc[2].to_string();
                } else {
                    driver_version = full;
                    driver_date.clear();
                }
            }
        }

        // Pass 2: fill whatever pass 1 left empty, by value shape. This is
        // the whole of what runs on a non-English machine.
        let mut class_guid_idx = None;
        for (i, line) in block.iter().enumerate() {
            let value = label_value(line);
            if published_name.is_none() && OEM_INF_RE.is_match(value) {
                published_name = Some(value.to_string());
            }
            if class_guid_idx.is_none() && CLASS_GUID_RE.is_match(value) {
                class_guid_idx = Some(i);
            }
            if driver_version.is_empty() {
                // Matched against the VALUE only. Against the whole line, a
                // provider or signer containing a date and a dotted number
                // could be captured as the driver version.
                if let Some(vc) = VERSION_VALUE_RE.captures(value) {
                    driver_date = vc[1].to_string();
                    driver_version = vc[2].to_string();
                }
            }
        }
        // The class name has no distinctive shape of its own, but pnputil
        // prints it directly above the class GUID in every locale.
        if class_name.is_empty() {
            if let Some(i) = class_guid_idx {
                if i > 0 {
                    class_name = label_value(block[i - 1]).to_string();
                }
            }
        }

        if let Some(published_name) = published_name {
            drivers.push(DriverEntry {
                published_name,
                class_name,
                driver_version,
                driver_date,
            });
        }
    }

    drivers.sort_by(|a, b| {
        a.class_name
            .to_lowercase()
            .cmp(&b.class_name.to_lowercase())
            .then_with(|| {
                a.published_name
                    .to_lowercase()
                    .cmp(&b.published_name.to_lowercase())
            })
    });

    drivers
}

#[cfg(test)]
mod tests {
    use super::*;

    /// pnputil translates every label. Before the shape-based fallback this
    /// returned zero drivers on any non-English Windows, and the Driver
    /// Store tab just showed an empty list with no error.
    #[test]
    fn parses_localized_pnputil_output() {
        // pt-BR labels, dd/mm/yyyy date.
        let pt = "\
Nome Publicado:      oem12.inf
Nome Original:       nvhda.inf
Nome do Fornecedor:  NVIDIA Corporation
Nome da Classe:      Controladores de som, v\u{ed}deo e jogo
GUID da Classe:      {4d36e96c-e325-11ce-bfc1-08002be10318}
Vers\u{e3}o do Driver:    13/06/2025 1.4.3.2
Nome do Signat\u{e1}rio: Microsoft Windows Hardware Compatibility Publisher
";
        let got = parse_pnputil_output(pt);
        assert_eq!(got.len(), 1, "localized block should still yield a driver");
        assert_eq!(got[0].published_name, "oem12.inf", "must not pick nvhda.inf");
        assert_eq!(got[0].class_name, "Controladores de som, v\u{ed}deo e jogo");
        assert_eq!(got[0].driver_version, "1.4.3.2");
        assert_eq!(got[0].driver_date, "13/06/2025");

        // de-DE labels, dotted date separator.
        let de = "\
Ver\u{f6}ffentlichter Name: oem7.inf
Originalname:          rtux.inf
Klassenname:           Audioeing\u{e4}nge und -ausg\u{e4}nge
Klassen-GUID:          {c166523c-fe0c-4a94-a586-f1a80cfbbf3e}
Treiberversion:        13.06.2025 6.0.9527.1
";
        let got = parse_pnputil_output(de);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].published_name, "oem7.inf");
        assert_eq!(got[0].class_name, "Audioeing\u{e4}nge und -ausg\u{e4}nge");
        assert_eq!(got[0].driver_version, "6.0.9527.1");
        assert_eq!(got[0].driver_date, "13.06.2025");
    }

    /// A provider or signer value carrying a date and a dotted number must
    /// not be mistaken for the driver version.
    #[test]
    fn localized_fallback_ignores_lookalike_values() {
        let text = "\
Nome Publicado:     oem3.inf
Nome do Fornecedor: Realtek 1.0
GUID da Classe:     {4d36e972-e325-11ce-bfc1-08002be10318}
Vers\u{e3}o do Driver:   01/02/2024 10.50.0.1
";
        let got = parse_pnputil_output(text);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].driver_version, "10.50.0.1");
        assert_eq!(got[0].driver_date, "01/02/2024");
    }

    #[test]
    fn parses_typical_pnputil_output() {
        let text = "\
Microsoft PnP Utility

Published Name:     oem12.inf
Original Name:      nvhda.inf
Provider Name:       NVIDIA
Class Name:          Sound, video and game controllers
Class GUID:          {4d36e96c-e325-11ce-bfc1-08002be10318}
Driver Version:      06/12/2024 10.28.0.1

Published Name:     oem3.inf
Original Name:      wacomvhid.inf
Provider Name:       Wacom Technology
Class Name:          HIDClass
Class GUID:          {745a17a0-74d3-11d0-b6fe-00a0c90f57da}
Driver Version:      01/05/2023 6.3.44.1

Total published Driver Store entries: 2
";
        let drivers = parse_pnputil_output(text);
        assert_eq!(drivers.len(), 2);
        // Sorted by class then published name: HIDClass before "Sound, ..."
        assert_eq!(drivers[0].class_name, "HIDClass");
        assert_eq!(drivers[0].published_name, "oem3.inf");
        assert_eq!(drivers[0].driver_date, "01/05/2023");
        assert_eq!(drivers[0].driver_version, "6.3.44.1");
        assert_eq!(drivers[1].class_name, "Sound, video and game controllers");
        assert_eq!(drivers[1].published_name, "oem12.inf");
    }

    #[test]
    fn empty_input_yields_no_drivers() {
        assert!(parse_pnputil_output("").is_empty());
        assert!(parse_pnputil_output("   \n  \n").is_empty());
    }

    #[test]
    fn ignores_blocks_without_published_name() {
        let text = "Microsoft PnP Utility\n\nTotal published Driver Store entries: 0\n";
        assert!(parse_pnputil_output(text).is_empty());
    }
}
