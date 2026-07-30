//! Background system queries for the Advanced tabs: installed packages
//! (winget/choco, for the pin picker), Windows services, and startup apps.
//! All commands run hidden with a timeout, mirroring `drivers::run_pnputil`.

use crate::pins::Manager;
use regex::Regex;
use std::collections::HashMap;
use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::sync::LazyLock;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// One installed package a pin can be created from.
#[derive(Debug, Clone)]
pub struct InstalledApp {
    pub id: String,
    pub name: String,
    pub manager: Manager,
}

/// One Windows service row.
#[derive(Debug, Clone)]
pub struct ServiceEntry {
    pub name: String,
    pub start_mode: String,
    pub state: String,
    pub display_name: String,
    /// Windows' own (localized) service description; shown as the
    /// plain-language explanation of what the service does.
    pub description: String,
}

/// One autostart entry (registry Run key or Startup folder item).
#[derive(Debug, Clone)]
pub struct StartupEntry {
    pub location: String,
    pub name: String,
    pub command: String,
    /// StartupApproved registry key that stores this item's on/off state
    /// (the same mechanism Task Manager uses). Empty = not toggleable
    /// (e.g. RunOnce entries, which fire once and delete themselves).
    pub approved_key: String,
    pub approved_name: String,
    pub enabled: bool,
}

impl StartupEntry {
    pub fn can_toggle(&self) -> bool {
        !self.approved_key.is_empty()
    }
}

/// One scheduled task that fires at boot or logon.
#[derive(Debug, Clone)]
pub struct TaskEntry {
    pub path: String,
    pub name: String,
    /// Ready / Running / Queued / Disabled (as reported by Get-ScheduledTask).
    pub state: String,
    /// First action's "Execute Arguments" (what the task actually runs).
    pub command: String,
    /// The task's own (often localized) description, if the author set one.
    pub description: String,
}

impl TaskEntry {
    pub fn enabled(&self) -> bool {
        !self.state.eq_ignore_ascii_case("disabled")
    }
}

/// Runs a command hidden and returns stdout, killing it after `timeout`.
/// `Id` / `Version` as standalone header words. `\b` rather than lookaround:
/// the `regex` crate supports no lookahead or lookbehind at all.
static ID_HEADER_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bId\b").unwrap());
static VERSION_HEADER_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bVers\w*\b").unwrap());

/// Byte offsets where each column of a header row starts. Columns are
/// separated by runs of two or more spaces.
fn column_starts(header: &str) -> Vec<usize> {
    let mut starts = Vec::new();
    let bytes = header.as_bytes();
    let mut i = 0;
    let mut in_gap = true;
    while i < bytes.len() {
        if bytes[i] == b' ' {
            if !in_gap && i + 1 < bytes.len() && bytes[i + 1] == b' ' {
                in_gap = true;
            }
        } else {
            if in_gap {
                starts.push(i);
            }
            in_gap = false;
        }
        i += 1;
    }
    starts
}

/// How long to wait for a child to actually die after we ask it to.
pub(crate) const KILL_GRACE: Duration = Duration::from_secs(2);

/// Waits up to `timeout` for `child` to exit. `None` means it didn't.
///
/// `Child::wait()` is unbounded. A child that closes stdout without exiting
/// used to hang the calling worker thread forever, which left the tab's
/// spinner spinning and its Refresh button disabled until the app restarted.
pub(crate) fn wait_bounded(child: &mut Child, timeout: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            // A transient `try_wait` error is not evidence the child is
            // stuck, so keep polling to the deadline rather than reporting a
            // spurious timeout.
            Ok(None) | Err(_) => {
                if Instant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

/// Kills `child` and, on Windows, every process it spawned.
///
/// `Child::kill()` terminates only the direct child, so a grandchild -- a
/// `Start-Process` from inside one of our scripts, say -- survives it and can
/// hold the stdout pipe open indefinitely.
pub(crate) fn kill_tree(child: &mut Child) {
    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/T", "/F", "/PID"])
            .arg(child.id().to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }
    let _ = child.kill();
}

fn run_hidden(program: &str, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
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
        return Err(format!("{program} timed out"));
    };
    // We have the output, so this call succeeds either way -- but the child
    // can close stdout without exiting, and leaving it alive would leak a
    // process per refresh. Reap it, and if it won't go, kill the tree.
    if wait_bounded(&mut child, KILL_GRACE).is_none() {
        kill_tree(&mut child);
        wait_bounded(&mut child, KILL_GRACE);
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn run_powershell(script: &str, timeout: Duration) -> Result<String, String> {
    // Force UTF-8 on the way out. `run_hidden` reads the pipe as UTF-8, but
    // powershell.exe encodes redirected stdout with [Console]::OutputEncoding,
    // which defaults to the OEM code page (437/850) -- so localized service
    // descriptions and any path under `C:\Usuários\...` came back as U+FFFD
    // replacement characters. This is the same thing `chcp 65001` does at the
    // top of SystemUpdate_Topgrade.bat.
    let script = format!(
        "[Console]::OutputEncoding = [Text.Encoding]::UTF8; {script}"
    );
    run_hidden(
        "powershell.exe",
        &["-NoProfile", "-NonInteractive", "-Command", &script],
        timeout,
    )
}

// ---------------------------------------------------------------------------
// Installed packages (pin picker)
// ---------------------------------------------------------------------------

/// Queries winget and choco (whichever respond) for locally installed
/// packages. Never fails outright: a missing manager just contributes none.
pub fn query_installed(timeout: Duration) -> Vec<InstalledApp> {
    let mut out = Vec::new();
    if let Ok(text) = run_hidden(
        "winget",
        &["list", "--accept-source-agreements", "--disable-interactivity"],
        timeout,
    ) {
        out.extend(parse_winget_list(&text));
    }
    if let Ok(text) = run_hidden("choco", &["list", "--limit-output"], timeout) {
        out.extend(parse_choco_list(&text));
    }
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

/// Parses `winget list` fixed-width output using the header's column offsets.
/// Rows whose Id is truncated (ends with the ellipsis winget prints) or that
/// have no real package id (ARP/MSIX fallbacks) are skipped: they can't be
/// pinned.
pub fn parse_winget_list(text: &str) -> Vec<InstalledApp> {
    let normalized = text.replace('\r', "\n");
    let rows: Vec<&str> = normalized
        .lines()
        .filter(|l| !l.trim().is_empty())
        .collect();

    // Find the header STRUCTURALLY: winget always underlines it with a run
    // of dashes. Keying off the word "Name" only worked in English - on a
    // pt-BR machine the header reads "Nome  Id  Versão  Fonte" and the pin
    // picker silently listed nothing at all.
    let is_rule = |l: &str| {
        let t = l.trim();
        t.len() >= 10 && t.chars().all(|c| c == '-')
    };
    let Some(header_idx) = (0..rows.len().saturating_sub(1)).find(|&i| is_rule(rows[i + 1])) else {
        return Vec::new();
    };
    let header = rows[header_idx];

    // "Id" is spelled the same in the locales winget ships, so prefer it as
    // the anchor; fall back to column positions when it isn't there.
    let id_col = ID_HEADER_RE
        .find(header)
        .map(|m| m.start())
        .or_else(|| column_starts(header).get(1).copied());
    let Some(id_col) = id_col else {
        return Vec::new();
    };
    let version_col = VERSION_HEADER_RE
        .find(header)
        .map(|m| m.start())
        .or_else(|| column_starts(header).get(2).copied());

    // Rows are everything after the dashed rule.
    let lines = rows.into_iter().skip(header_idx + 2);

    // winget pads columns by display width; treating them as char offsets is
    // correct for the header itself (pure ASCII) and close enough for rows -
    // rows that would mis-slice are filtered by the id validity check below.
    let id_start = header[..id_col].chars().count();
    let id_end = version_col.map(|v| header[..v].chars().count());

    let mut out = Vec::new();
    for line in lines {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('-') {
            continue;
        }
        let chars: Vec<char> = line.chars().collect();
        if chars.len() <= id_start {
            continue;
        }
        let name: String = chars[..id_start].iter().collect();
        let rest: String = match id_end {
            Some(end) if chars.len() > end => chars[id_start..end].iter().collect(),
            _ => chars[id_start..].iter().collect(),
        };
        let id = rest.trim().to_string();
        let name = name.trim().to_string();
        // Valid winget ids look like Publisher.Package (or msstore's 12-char
        // product codes); skip truncated ("…"), ARP\..., MSIX\... and empties.
        if id.is_empty()
            || id.ends_with('\u{2026}')
            || name.ends_with('\u{2026}')
            || id.contains('\\')
            || id.contains(' ')
        {
            continue;
        }
        out.push(InstalledApp {
            id,
            name,
            manager: Manager::Winget,
        });
    }
    out
}

/// Parses `choco list --limit-output` ("name|version" per line).
pub fn parse_choco_list(text: &str) -> Vec<InstalledApp> {
    text.lines()
        .filter_map(|l| {
            let (name, _version) = l.trim().split_once('|')?;
            if name.is_empty() || name.contains(' ') {
                return None;
            }
            Some(InstalledApp {
                id: name.to_string(),
                name: name.to_string(),
                manager: Manager::Choco,
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

const SERVICES_SCRIPT: &str = r#"Get-CimInstance Win32_Service | ForEach-Object { $_.Name + [char]9 + $_.StartMode + [char]9 + $_.State + [char]9 + $_.DisplayName + [char]9 + (([string]$_.Description) -replace "\s+", " ") }"#;

pub fn query_services(timeout: Duration) -> Result<Vec<ServiceEntry>, String> {
    run_powershell(SERVICES_SCRIPT, timeout).map(|text| parse_services(&text))
}

pub fn parse_services(text: &str) -> Vec<ServiceEntry> {
    let mut out: Vec<ServiceEntry> = text
        .lines()
        .filter_map(|l| {
            let mut parts = l.splitn(5, '\t');
            let name = parts.next()?.trim();
            let start_mode = parts.next()?.trim();
            let state = parts.next()?.trim();
            let display_name = parts.next().unwrap_or("").trim();
            let description = parts.next().unwrap_or("").trim();
            if name.is_empty() {
                return None;
            }
            Some(ServiceEntry {
                name: name.to_string(),
                start_mode: start_mode.to_string(),
                state: state.to_string(),
                display_name: display_name.to_string(),
                description: description.to_string(),
            })
        })
        .collect();
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

/// Changes a service's startup type via `Set-Service`. `start_type` must be
/// one of Automatic / Manual / Disabled. Requires elevation (the dashboard
/// always runs elevated). Returns stderr-ish detail on failure.
pub fn set_service_start_mode(name: &str, start_type: &str) -> Result<(), String> {
    if !matches!(start_type, "Automatic" | "Manual" | "Disabled") {
        return Err(format!("invalid start type: {start_type}"));
    }
    let script = format!(
        "try {{ Set-Service -Name '{}' -StartupType {} -ErrorAction Stop; 'OK' }} catch {{ 'ERR: ' + $_.Exception.Message }}",
        name.replace('\'', "''"),
        start_type
    );
    let out = run_powershell(&script, Duration::from_secs(30))?;
    let out = out.trim();
    if out.starts_with("OK") {
        Ok(())
    } else {
        Err(out.trim_start_matches("ERR: ").to_string())
    }
}

// ---------------------------------------------------------------------------
// Startup apps
// ---------------------------------------------------------------------------

// Emits: location, name, command, approvedKey, approvedName, enabled(1/0).
// StartupApproved is the on/off store Task Manager itself uses: first byte
// even = enabled, odd = disabled. Items without an approved key (RunOnce)
// can't be toggled.
const STARTUP_SCRIPT: &str = r#"
function Emit($loc, $name, $cmd, $aKey, $aName) {
    $enabled = 1
    if ($aKey) {
        try {
            $v = (Get-ItemProperty -Path $aKey -Name $aName -ErrorAction Stop).$aName
            if ($v -and ($v[0] -band 1)) { $enabled = 0 }
        } catch {}
    }
    $loc + [char]9 + $name + [char]9 + $cmd + [char]9 + $aKey + [char]9 + $aName + [char]9 + $enabled
}
$runPairs = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)
foreach ($p in $runPairs) {
    if (Test-Path $p.Key) {
        (Get-ItemProperty $p.Key).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' } |
            ForEach-Object { Emit $p.Key $_.Name ([string]$_.Value) $p.Approved $_.Name }
    }
}
foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce')) {
    if (Test-Path $k) {
        (Get-ItemProperty $k).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' } |
            ForEach-Object { Emit $k $_.Name ([string]$_.Value) '' '' }
    }
}
$folderPairs = @(
    @{ Dir = [Environment]::GetFolderPath('Startup');
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
    @{ Dir = [Environment]::GetFolderPath('CommonStartup');
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
)
foreach ($f in $folderPairs) {
    if ($f.Dir -and (Test-Path $f.Dir)) {
        Get-ChildItem -LiteralPath $f.Dir -File |
            Where-Object { $_.Name -ne 'desktop.ini' } |
            ForEach-Object { Emit $f.Dir $_.Name $_.FullName $f.Approved $_.Name }
    }
}
"#;

pub fn query_startup(timeout: Duration) -> Result<Vec<StartupEntry>, String> {
    run_powershell(STARTUP_SCRIPT, timeout).map(|text| parse_startup(&text))
}

pub fn parse_startup(text: &str) -> Vec<StartupEntry> {
    let mut out: Vec<StartupEntry> = text
        .lines()
        .filter_map(|l| {
            let mut parts = l.splitn(6, '\t');
            let location = parts.next()?.trim();
            let name = parts.next()?.trim();
            let command = parts.next()?.trim();
            let approved_key = parts.next().unwrap_or("").trim();
            let approved_name = parts.next().unwrap_or("").trim();
            let enabled = parts.next().unwrap_or("1").trim() != "0";
            if location.is_empty() || name.is_empty() {
                return None;
            }
            Some(StartupEntry {
                location: location.to_string(),
                name: name.to_string(),
                command: command.to_string(),
                approved_key: approved_key.to_string(),
                approved_name: approved_name.to_string(),
                enabled,
            })
        })
        .collect();
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

/// Enables/disables a startup item by writing its StartupApproved value —
/// the exact mechanism Task Manager's Startup tab uses. Nothing is deleted;
/// flipping back on restores the original behavior.
pub fn set_startup_enabled(
    approved_key: &str,
    approved_name: &str,
    enable: bool,
) -> Result<(), String> {
    if approved_key.is_empty() || approved_name.is_empty() {
        return Err("this entry cannot be toggled".to_string());
    }
    let first_byte = if enable { 2 } else { 3 };
    let script = format!(
        r#"try {{
    if (-not (Test-Path '{key}')) {{ New-Item -Path '{key}' -Force | Out-Null }}
    $bytes = [byte[]]@({first_byte},0,0,0,0,0,0,0,0,0,0,0)
    New-ItemProperty -Path '{key}' -Name '{name}' -Value $bytes -PropertyType Binary -Force | Out-Null
    'OK'
}} catch {{ 'ERR: ' + $_.Exception.Message }}"#,
        key = approved_key.replace('\'', "''"),
        name = approved_name.replace('\'', "''"),
        first_byte = first_byte,
    );
    let out = run_powershell(&script, Duration::from_secs(30))?;
    let out = out.trim();
    if out.starts_with("OK") {
        Ok(())
    } else {
        Err(out.trim_start_matches("ERR: ").to_string())
    }
}

// ---------------------------------------------------------------------------
// Scheduled tasks (boot/logon triggers only — the ones that affect startup)
// ---------------------------------------------------------------------------

// Trigger type is matched via PSObject.TypeNames: on some systems the
// CimClass property of trigger instances doesn't resolve inside script
// blocks (observed live), while the type name always carries
// ...MSFT_TaskLogonTrigger / MSFT_TaskBootTrigger.
const TASKS_SCRIPT: &str = r#"
Get-ScheduledTask | ForEach-Object {
    $triggers = @($_.Triggers) | Where-Object { $_ -and ($_.PSObject.TypeNames -match 'LogonTrigger|BootTrigger') }
    if (@($triggers).Count -gt 0) {
        $act = @($_.Actions) | Where-Object { $_.Execute } | Select-Object -First 1
        $cmd = if ($act) { ($act.Execute + ' ' + $act.Arguments).Trim() } else { '' }
        $desc = (([string]$_.Description) -replace "\s+", " ").Trim()
        $_.TaskPath + [char]9 + $_.TaskName + [char]9 + $_.State + [char]9 + $cmd + [char]9 + $desc
    }
}
"#;

pub fn query_tasks(timeout: Duration) -> Result<Vec<TaskEntry>, String> {
    run_powershell(TASKS_SCRIPT, timeout).map(|text| parse_tasks(&text))
}

pub fn parse_tasks(text: &str) -> Vec<TaskEntry> {
    let mut out: Vec<TaskEntry> = text
        .lines()
        .filter_map(|l| {
            let mut parts = l.splitn(5, '\t');
            let path = parts.next()?.trim();
            let name = parts.next()?.trim();
            let state = parts.next().unwrap_or("").trim();
            let command = parts.next().unwrap_or("").trim();
            let description = parts.next().unwrap_or("").trim();
            if name.is_empty() {
                return None;
            }
            Some(TaskEntry {
                path: path.to_string(),
                name: name.to_string(),
                state: state.to_string(),
                command: command.to_string(),
                description: description.to_string(),
            })
        })
        .collect();
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

/// Extracts the program name from a command line ("C:\..\Docker Desktop.exe"
/// --flag -> "Docker Desktop.exe") for friendly fallback descriptions.
pub fn exe_name(command: &str) -> String {
    let trimmed = command.trim();
    let path = if let Some(rest) = trimmed.strip_prefix('"') {
        rest.split('"').next().unwrap_or("")
    } else {
        // Unquoted AND containing spaces is normal in Run keys
        // (`C:\Program Files\Docker\Docker Desktop.exe --autostart`), so
        // splitting on the first space yielded "Program". Cut at the last
        // `.exe`-ish token instead and only fall back to the first word when
        // there is no recognizable executable extension.
        exe_prefix(trimmed).unwrap_or_else(|| trimmed.split_whitespace().next().unwrap_or(""))
    };
    path.rsplit(['\\', '/'])
        .next()
        .unwrap_or("")
        .to_string()
}

/// The leading path of an unquoted command line, up to and including the
/// first executable extension. `None` when there isn't one.
fn exe_prefix(command: &str) -> Option<&str> {
    const EXTS: [&str; 4] = [".exe", ".bat", ".cmd", ".com"];
    let lower = command.to_ascii_lowercase();
    EXTS.iter()
        .filter_map(|ext| lower.find(ext).map(|i| i + ext.len()))
        // A trailing `.exe` must end the token, not sit inside a longer word.
        .filter(|end| {
            command[*end..]
                .chars()
                .next()
                .is_none_or(|c| c.is_whitespace())
        })
        .min()
        .map(|end| &command[..end])
}

/// Enables/disables a scheduled task via Enable-/Disable-ScheduledTask.
pub fn set_task_enabled(path: &str, name: &str, enable: bool) -> Result<(), String> {
    if path.is_empty() || name.is_empty() {
        return Err("invalid task reference".to_string());
    }
    let verb = if enable {
        "Enable-ScheduledTask"
    } else {
        "Disable-ScheduledTask"
    };
    let script = format!(
        "try {{ {verb} -TaskPath '{}' -TaskName '{}' -ErrorAction Stop | Out-Null; 'OK' }} catch {{ 'ERR: ' + $_.Exception.Message }}",
        path.replace('\'', "''"),
        name.replace('\'', "''"),
    );
    let out = run_powershell(&script, Duration::from_secs(30))?;
    let out = out.trim();
    if out.starts_with("OK") {
        Ok(())
    } else {
        Err(out.trim_start_matches("ERR: ").to_string())
    }
}

// ---------------------------------------------------------------------------
// Measured startup load times (boot-times.json, seconds per item name)
// ---------------------------------------------------------------------------

/// Loads root/boot-times.json: a flat lowercase-name -> seconds map measured
/// externally (e.g. copied from Glary's Startup Manager). Missing or broken
/// file just yields an empty map — the Time column then stays blank.
pub fn load_boot_times(root: &Path) -> HashMap<String, f64> {
    let Ok(text) = std::fs::read_to_string(root.join("boot-times.json")) else {
        return HashMap::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
        return HashMap::new();
    };
    let Some(obj) = value.as_object() else {
        return HashMap::new();
    };
    obj.iter()
        .filter(|(k, _)| !k.starts_with('_'))
        .filter_map(|(k, v)| v.as_f64().map(|f| (k.trim().to_lowercase(), f)))
        .collect()
}

/// Case-insensitive lookup that also strips per-user suffixes
/// ("Clipboard User Service_223a20" -> "clipboard user service").
pub fn boot_time_for(map: &HashMap<String, f64>, name: &str) -> Option<f64> {
    let n = name.trim().to_lowercase();
    if let Some(v) = map.get(&n) {
        return Some(*v);
    }
    if let Some(pos) = n.rfind('_') {
        let (base, suffix) = n.split_at(pos);
        if suffix.len() > 1 && suffix[1..].chars().all(|c| c.is_ascii_hexdigit()) {
            if let Some(v) = map.get(base) {
                return Some(*v);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// winget localizes its column headers. Detecting the header by the word
    /// "Name" meant the pin picker listed nothing at all on a pt-BR machine,
    /// with no error to explain it.
    #[test]
    fn parses_localized_winget_list() {
        let text = "\
Nome                        Id                        Vers\u{e3}o       Fonte
--------------------------------------------------------------------------
7-Zip 24.09 (x64)           7zip.7zip                 24.09        winget
Git                         Git.Git                   2.47.0       winget
";
        let apps = parse_winget_list(text);
        let ids: Vec<&str> = apps.iter().map(|a| a.id.as_str()).collect();
        assert!(
            ids.contains(&"7zip.7zip") && ids.contains(&"Git.Git"),
            "localized header should still yield rows, got {ids:?}"
        );
    }

    /// Header detection must not depend on any recognizable word: fall back
    /// to column positions under the dashed rule.
    #[test]
    fn parses_winget_list_with_unrecognizable_headers() {
        let text = "\
\u{540d}\u{524d}                        \u{8b58}\u{5225}\u{5b50}                    \u{30d0}\u{30fc}\u{30b8}\u{30e7}\u{30f3}
--------------------------------------------------------------------------
7-Zip 24.09 (x64)           7zip.7zip                 24.09
";
        let apps = parse_winget_list(text);
        assert_eq!(apps.len(), 1, "should fall back to column offsets");
        assert_eq!(apps[0].id, "7zip.7zip");
    }

    #[test]
    fn parses_winget_list_columns() {
        let text = "\
Name                        Id                        Version      Available Source
-----------------------------------------------------------------------------------
7-Zip 24.09 (x64)           7zip.7zip                 24.09                  winget
Brave                       Brave.Brave               1.81.62      1.81.100  winget
Some Store App              9NBLGGH4NNS1              1.0                    msstore
Legacy thing                ARP\\Machine\\X64\\Legacy  1.0
Truncated Name that is lo\u{2026} Some.Id                  1.0                    winget
";
        let apps = parse_winget_list(text);
        let ids: Vec<&str> = apps.iter().map(|a| a.id.as_str()).collect();
        assert!(ids.contains(&"7zip.7zip"));
        assert!(ids.contains(&"Brave.Brave"));
        assert!(ids.contains(&"9NBLGGH4NNS1"));
        // ARP fallback and truncated rows are unpinnable -> skipped.
        assert!(!ids.iter().any(|i| i.contains('\\')));
        assert!(!ids.contains(&"Some.Id"));
        assert!(apps.iter().all(|a| a.manager == Manager::Winget));
    }

    #[test]
    fn winget_parse_survives_garbage() {
        assert!(parse_winget_list("").is_empty());
        assert!(parse_winget_list("no header here\njust noise").is_empty());
    }

    #[test]
    fn parses_choco_limit_output() {
        let apps = parse_choco_list("7zip|24.09\r\nffmpeg|7.1\r\n");
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].id, "7zip");
        assert!(apps.iter().all(|a| a.manager == Manager::Choco));
    }

    #[test]
    fn parses_services_tsv() {
        let text = "wuauserv\tManual\tStopped\tWindows Update\tEnables download and installation of updates.\nSpooler\tAuto\tRunning\tPrint Spooler\t\n";
        let s = parse_services(text);
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].name, "Spooler"); // sorted
        assert_eq!(s[1].display_name, "Windows Update");
        assert!(s[1].description.starts_with("Enables download"));
        assert!(s[0].description.is_empty());
    }

    #[test]
    fn parses_startup_tsv_with_toggle_state() {
        let text = "HKCU:\\...\\Run\tOneDrive\tC:\\OneDrive.exe /background\tHKCU:\\...\\StartupApproved\\Run\tOneDrive\t0\nC:\\Users\\X\\Startup\tMyTool.lnk\tC:\\tool.lnk\tHKCU:\\...\\StartupApproved\\StartupFolder\tMyTool.lnk\t1\nHKCU:\\...\\RunOnce\tOneShot\tC:\\x.exe\t\t\t1\n";
        let s = parse_startup(text);
        assert_eq!(s.len(), 3);
        // Sorted by name: MyTool.lnk, OneDrive, OneShot
        assert_eq!(s[0].name, "MyTool.lnk");
        assert!(s[0].enabled && s[0].can_toggle());
        assert_eq!(s[1].name, "OneDrive");
        assert!(!s[1].enabled && s[1].can_toggle());
        assert_eq!(s[2].name, "OneShot");
        assert!(!s[2].can_toggle());
    }

    #[test]
    fn rejects_bad_service_start_type() {
        assert!(set_service_start_mode("x", "Bogus").is_err());
        assert!(set_startup_enabled("", "", true).is_err());
        assert!(set_task_enabled("", "", true).is_err());
    }

    #[test]
    fn boot_time_lookup_strips_user_suffix() {
        let mut map = HashMap::new();
        map.insert("clipboard user service".to_string(), 0.1_f64);
        map.insert("tailscale".to_string(), 1.1_f64);
        assert_eq!(boot_time_for(&map, "Tailscale"), Some(1.1));
        assert_eq!(boot_time_for(&map, "Clipboard User Service_223a20"), Some(0.1));
        assert_eq!(boot_time_for(&map, "Unknown Thing"), None);
    }

    #[test]
    fn parses_tasks_tsv() {
        let text = "\\Microsoft\\Windows\\OneDrive\\\tOneDrive Startup Task\tReady\tC:\\OneDrive.exe /run\tKeeps OneDrive running.\n\\\tAutorun for User\tDisabled\tC:\\PT\\PowerToys.exe\t\n";
        let tasks = parse_tasks(text);
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].name, "Autorun for User");
        assert!(!tasks[0].enabled());
        assert!(tasks[0].description.is_empty());
        assert!(tasks[1].enabled());
        assert_eq!(tasks[1].path, "\\Microsoft\\Windows\\OneDrive\\");
        assert_eq!(tasks[1].command, "C:\\OneDrive.exe /run");
        assert_eq!(tasks[1].description, "Keeps OneDrive running.");
    }

    #[test]
    fn exe_name_handles_quotes_and_args() {
        assert_eq!(
            exe_name("\"C:\\Program Files\\Docker\\Docker Desktop.exe\" --autostart"),
            "Docker Desktop.exe"
        );
        assert_eq!(exe_name("C:\\Windows\\cmd.exe /c echo"), "cmd.exe");
        assert_eq!(exe_name(""), "");
    }

    /// Run keys routinely hold an UNQUOTED path with spaces. Splitting on the
    /// first space showed these items as "Program" in the UI.
    #[test]
    fn exe_name_handles_unquoted_paths_with_spaces() {
        assert_eq!(
            exe_name("C:\\Program Files\\Docker\\Docker Desktop.exe --autostart"),
            "Docker Desktop.exe"
        );
        assert_eq!(
            exe_name("C:\\Program Files\\Everything\\Everything.exe -startup"),
            "Everything.exe"
        );
        assert_eq!(
            exe_name("C:\\ProgramData\\SquirrelMachineInstalls\\Discord.exe --checkInstall"),
            "Discord.exe"
        );
        assert_eq!(exe_name("C:\\some\\thing.bat arg"), "thing.bat");
        // No recognizable extension: fall back to the first token rather than
        // swallowing the whole argument list.
        assert_eq!(exe_name("rundll32 shell32.dll,Control_RunDLL"), "rundll32");
    }
}
