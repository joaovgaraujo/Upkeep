//! Spawns the SystemUpdate_Topgrade.bat engine, streams its output back to
//! the UI thread over a single mpsc channel, and parses its `[tag]` markers
//! and end-of-run summary block.

use crate::drivers::DriverEntry;
use crate::reboot::RebootFlags;
use crate::system::{kill_tree, wait_bounded, KILL_GRACE};
use regex::Regex;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, LazyLock};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(windows)]
pub const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

/// How long to keep the engine process alive after its summary block has
/// been fully parsed before force-killing it. The bat's own `timeout /t 60`
/// would otherwise sit there waiting for a keypress that will never come.
const POST_SUMMARY_GRACE: Duration = Duration::from_secs(65);

/// How long to keep draining buffered output after the child has exited.
///
/// The channel normally disconnects on its own once both reader threads
/// finish, and that is the clean way out of the stream loop. This bound only
/// matters when a *grandchild* inherited the pipes and outlives the run (a
/// background launcher, say), because then the reader threads never see EOF
/// and the channel never disconnects.
const EXIT_DRAIN_GRACE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Category {
    WindowsUpdate,
    Store,
    Apps,
    Steam,
    Drivers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Idle,
    Running,
    Ok,
    Error,
    Skipped,
}

#[derive(Debug, Clone, Default)]
pub struct SummaryData {
    pub winget: Option<String>,
    pub topgrade: Option<String>,
    pub windows_update: Option<String>,
    pub store: Option<String>,
    pub steam: Option<String>,
    pub jdownloader: Option<String>,
    pub ea_app: Option<String>,
    pub duration: Option<String>,
    pub log_path: Option<String>,
}

impl SummaryData {
    /// True when every field is `None` — the shape produced by parsing a
    /// non-summary `========` block (e.g. the bat's opening banner). Used to
    /// defensively drop bogus `Summary` events even if a parser edge case
    /// somehow lets one through.
    pub fn is_empty(&self) -> bool {
        self.winget.is_none()
            && self.topgrade.is_none()
            && self.windows_update.is_none()
            && self.store.is_none()
            && self.steam.is_none()
            && self.jdownloader.is_none()
            && self.ea_app.is_none()
            && self.duration.is_none()
            && self.log_path.is_none()
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SkipFlags {
    pub skip_winupdate: bool,
    pub skip_store: bool,
    pub skip_apps: bool,
    pub skip_steam: bool,
}

/// How the engine process ended. A dedicated enum instead of an `i32` with a
/// `-1` sentinel: "stopped by us / code unknowable" and "exited with code -1"
/// are different facts and the type system should keep them apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineExit {
    /// The process exited on its own with this code.
    Code(i32),
    /// The dashboard stopped it (post-summary watchdog), it never launched,
    /// or the OS reported no exit code — the real code is unknowable.
    Stopped,
}

pub enum AppEvent {
    LogLine(String),
    CategoryStatus(Category, Status),
    Summary(SummaryData),
    EngineExited(EngineExit),
    /// Reserved for a future background/periodic reboot poll; today the
    /// dashboard checks the registry synchronously on the UI thread (it's a
    /// handful of fast key lookups) on startup and before each run.
    #[allow(dead_code)]
    RebootStatus(RebootFlags),
    DriverList(Vec<DriverEntry>),
    InstalledApps(Vec<crate::system::InstalledApp>),
    ServiceList(Result<Vec<crate::system::ServiceEntry>, String>),
    StartupList(Result<Vec<crate::system::StartupEntry>, String>),
    TaskList(Result<Vec<crate::system::TaskEntry>, String>),
    Error(String),
}

fn strip_ansi(line: &str) -> String {
    strip_ansi_escapes::strip_str(line)
}

/// Maps a log line's leading `[tag]` to the category whose status chip it
/// should flip to "running". Mirrors Functions.ps1's Get-CategoryFromMarker,
/// extended with a distinct Steam category per the dashboard's sidebar.
fn category_from_tag(line: &str) -> Option<Category> {
    let lower = line.to_lowercase();
    if lower.contains("[winupdate]") {
        Some(Category::WindowsUpdate)
    } else if lower.contains("[store]") {
        Some(Category::Store)
    } else if lower.contains("[steam]") {
        Some(Category::Steam)
    } else if lower.contains("[winget]")
        || lower.contains("[ea]")
        || lower.contains("[launch]")
        || lower.contains("[jdownloader]")
        || lower.contains("[setup]")
        || lower.contains("[pins]")
        || lower.contains("[discord]")
        || lower.contains("[explicit]")
        || lower.contains("[run]")
    {
        Some(Category::Apps)
    } else {
        None
    }
}

static DURATION_HEADER_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)duration\s*:\s*(.+?)\s*\)").unwrap());
static KV_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*(.+?)\s*:\s*(.+?)\s*$").unwrap());
static SEP_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*[=\-]+\s*$").unwrap());

fn parse_summary(text: &str) -> SummaryData {
    let mut data = SummaryData::default();

    for line in text.lines() {
        if SEP_RE.is_match(line) || line.trim().is_empty() {
            continue;
        }

        if let Some(c) = DURATION_HEADER_RE.captures(line) {
            data.duration = Some(c[1].trim().to_string());
            continue;
        }

        if let Some(c) = KV_RE.captures(line) {
            let key = c[1].trim().to_lowercase();
            let value = c[2].trim().to_string();
            match key.as_str() {
                "winget" => data.winget = Some(value),
                "topgrade" => data.topgrade = Some(value),
                "windows update" => data.windows_update = Some(value),
                "ea app" => data.ea_app = Some(value),
                "duration" => data.duration = Some(value),
                "store" => data.store = Some(value),
                "steam" | "steam games" => data.steam = Some(value),
                "jdownloader" => data.jdownloader = Some(value),
                "log" => data.log_path = Some(value),
                _ => {}
            }
        }
    }

    data
}

/// Spawns the engine hidden and streams its combined stdout/stderr back
/// through `tx` as it runs, on a background thread. Returns immediately.
/// `stop` asks the run to end early: the loop polls it, kills the process
/// TREE and exits as `EngineExit::Stopped`. `finished` is set once this
/// thread is completely done, so the UI can wait a bounded time for it on
/// window close instead of orphaning the whole update chain.
pub fn spawn_engine(
    bat_path: PathBuf,
    root: PathBuf,
    skip: SkipFlags,
    tx: Sender<AppEvent>,
    ctx: egui::Context,
    stop: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        // Set on every exit path below, including early returns.
        struct MarkFinished(Arc<AtomicBool>);
        impl Drop for MarkFinished {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let _finished = MarkFinished(finished);

        let mut cmd = Command::new("cmd.exe");
        cmd.arg("/c").arg(&bat_path);
        cmd.current_dir(&root);
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);

        // Tells the bat nobody is watching a console: skip its prompts and
        // the closing countdown. `pause`/`timeout` can't run against the
        // null stdin above and would otherwise write "ERROR: Input
        // redirection is not supported" to stderr, straight into our log.
        cmd.env("DASHBOARD_RUN", "1");

        for (key, skip_it) in [
            ("DASHBOARD_SKIP_WINUPDATE", skip.skip_winupdate),
            ("DASHBOARD_SKIP_STORE", skip.skip_store),
            ("DASHBOARD_SKIP_APPS", skip.skip_apps),
            ("DASHBOARD_SKIP_STEAM", skip.skip_steam),
        ] {
            if skip_it {
                cmd.env(key, "1");
            } else {
                cmd.env_remove(key);
            }
        }

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let _ = tx.send(AppEvent::Error(format!(
                    "Failed to launch engine: {e} (path: {})",
                    bat_path.display()
                )));
                let _ = tx.send(AppEvent::EngineExited(EngineExit::Stopped));
                ctx.request_repaint();
                return;
            }
        };

        run_and_stream(&mut child, &tx, &ctx, &stop);
    });
}

/// Internal line coming off either stdout or stderr, tagged by source.
enum RawLine {
    Out(String),
    Err(String),
}

fn run_and_stream(
    child: &mut Child,
    tx: &Sender<AppEvent>,
    ctx: &egui::Context,
    stop: &AtomicBool,
) {
    let (line_tx, line_rx) = mpsc::channel::<RawLine>();

    if let Some(stdout) = child.stdout.take() {
        let line_tx = line_tx.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                if line_tx.send(RawLine::Out(line)).is_err() {
                    break;
                }
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        let line_tx = line_tx.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                if line_tx.send(RawLine::Err(line)).is_err() {
                    break;
                }
            }
        });
    }
    // Drop our own handle so the channel disconnects once both reader
    // threads (which hold the remaining clones) have exited.
    drop(line_tx);

    let mut state = SummaryState::default();
    // Set the first time the child is seen to have exited: its status, plus
    // the instant after which we stop waiting for buffered output to drain.
    let mut exited: Option<(std::process::ExitStatus, Instant)> = None;

    let final_status = loop {
        // Stop requested (button, or the window closing). `break None`
        // rather than returning early: the tail below flushes a held line
        // and any partial summary, and sends EngineExited exactly once.
        if stop.load(Ordering::Relaxed) {
            // The child is cmd.exe; the .bat and everything it launched are
            // its descendants, so only a TREE kill actually stops the run.
            kill_tree(child);
            wait_bounded(child, KILL_GRACE);
            break None;
        }

        // Watchdog: kill the process once the post-summary grace period
        // elapses, since the bat sits on `timeout /t 60` waiting for a
        // keypress that will never come from a headless spawn.
        if let Some(deadline) = state.summary_deadline {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }

        match line_rx.recv_timeout(Duration::from_millis(150)) {
            Ok(RawLine::Out(raw)) => process_line(&raw, false, tx, ctx, &mut state),
            Ok(RawLine::Err(raw)) => process_line(&raw, true, tx, ctx, &mut state),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                // Both reader threads have finished, meaning every process
                // holding the pipes (the bat and anything it spawned) has
                // exited or released them — a blocking wait returns promptly.
                break child.wait().ok();
            }
        }

        match child.try_wait() {
            // The child exiting does NOT mean its output has been consumed:
            // the reader threads can still hold buffered lines that nothing
            // has pulled off the channel yet. Breaking here outright dropped
            // every one of them, which hurt most in the case that matters --
            // a run that fails fast, prints why, and exits, leaving the log
            // pane with one line and "no summary" instead of the diagnostic.
            // Keep looping so the queued lines drain, and leave through the
            // Disconnected arm above; the deadline is only a backstop for
            // pipes held open by a surviving grandchild.
            Ok(Some(status)) => {
                let (_, deadline) =
                    *exited.get_or_insert((status, Instant::now() + EXIT_DRAIN_GRACE));
                if Instant::now() >= deadline {
                    break Some(status);
                }
            }
            Ok(None) => {}
            Err(_) => break None,
        }
    };

    let exit = match final_status {
        Some(status) => status.code().map_or(EngineExit::Stopped, EngineExit::Code),
        None => EngineExit::Stopped,
    };

    // Flush a held `========` line that never got its lookahead line (the
    // process exited right after printing it) as a plain log line.
    if let Some(held) = state.pending_open.take() {
        let _ = tx.send(AppEvent::LogLine(held));
    }

    // Drain any summary lines that never saw a closing marker (e.g. killed
    // mid-block); parse what we have so partial info still surfaces.
    if state.in_summary && !state.summary_lines.is_empty() {
        let text = state.summary_lines.join("\n");
        let _ = tx.send(AppEvent::Summary(parse_summary(&text)));
    }

    let _ = tx.send(AppEvent::EngineExited(exit));
    ctx.request_repaint();
}

/// Mutable state threaded through successive `process_line` calls for a
/// single engine run, tracking the summary-block parser and its watchdog.
#[derive(Default)]
struct SummaryState {
    in_summary: bool,
    summary_lines: Vec<String>,
    summary_deadline: Option<Instant>,
    /// Holds a `========` line that hasn't yet been confirmed as the
    /// opening of a real summary block (see `process_line`).
    pending_open: Option<String>,
}

/// Processes one line of engine output, updating the summary-block state
/// machine and forwarding category/log/summary events to the UI thread.
///
/// A `========` line only opens a summary block if the *next* line starts
/// with (optional whitespace then) "Summary" — the real block's second line
/// is always "  Summary  (duration: HH:MM:SS)". Any other `========` line
/// (e.g. the bat's opening banner, immediately followed by "  System Update
/// via Topgrade") is just logged normally and never arms the post-summary
/// watchdog or emits a (bogus, all-`None`) `Summary` event.
///
/// This is implemented as a one-line lookahead: a `========` line is held in
/// `state.pending_open` until the following line arrives and confirms or
/// refutes it.
fn process_line(
    raw: &str,
    is_err: bool,
    tx: &Sender<AppEvent>,
    ctx: &egui::Context,
    state: &mut SummaryState,
) {
    let clean = strip_ansi(raw);
    let display = if is_err {
        format!("[stderr] {clean}")
    } else {
        clean
    };

    if let Some(cat) = category_from_tag(&display) {
        let _ = tx.send(AppEvent::CategoryStatus(cat, Status::Running));
    }

    // Resolve a held `========` line using this line as lookahead.
    if let Some(held) = state.pending_open.take() {
        if display.trim_start().starts_with("Summary") {
            // Confirmed: `held` is the real opening marker of a summary
            // block; this line is its "Summary (duration: ...)" header.
            state.in_summary = true;
            state.summary_lines.clear();
            state.summary_lines.push(held.clone());
        }
        // Whether confirmed or not, `held` is real console output and gets
        // logged (in order, ahead of the current line).
        let _ = tx.send(AppEvent::LogLine(held));
    }

    let is_sep = display.trim_start().starts_with("========");

    if is_sep && !state.in_summary {
        // Potential opening marker: hold it until the next line confirms or
        // refutes a real summary block. Deliberately not logged yet — it is
        // logged above once resolved (or flushed at stream end).
        state.pending_open = Some(display);
        ctx.request_repaint();
        return;
    }

    if is_sep {
        // Closing marker of a confirmed summary block.
        state.summary_lines.push(display.clone());
        state.in_summary = false;
        let text = state.summary_lines.join("\n");
        let _ = tx.send(AppEvent::Summary(parse_summary(&text)));
        state.summary_deadline = Some(Instant::now() + POST_SUMMARY_GRACE);
    } else if state.in_summary {
        state.summary_lines.push(display.clone());
    }

    let _ = tx.send(AppEvent::LogLine(display));
    ctx.request_repaint();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_engine_summary_block() {
        let text = "\
========================================
  Summary  (duration: 00:12:34)
----------------------------------------
  winget          : ok
  topgrade        : ok
  Windows Update  : skipped
  Store           : ok
  Steam games     : ok
  JDownloader     : skipped
  EA app          : n/a
----------------------------------------
  Log: C:\\Users\\me\\Documents\\SystemUpdateLogs\\Topgrade_20260101_010101.log
========================================";
        let data = parse_summary(text);
        assert_eq!(data.duration.as_deref(), Some("00:12:34"));
        assert_eq!(data.winget.as_deref(), Some("ok"));
        assert_eq!(data.topgrade.as_deref(), Some("ok"));
        assert_eq!(data.windows_update.as_deref(), Some("skipped"));
        assert_eq!(data.store.as_deref(), Some("ok"));
        assert_eq!(data.steam.as_deref(), Some("ok"));
        assert_eq!(data.jdownloader.as_deref(), Some("skipped"));
        assert_eq!(data.ea_app.as_deref(), Some("n/a"));
        assert!(data
            .log_path
            .unwrap()
            .ends_with("Topgrade_20260101_010101.log"));
    }

    /// Regression test for the watchdog false-trigger: the bat's very first
    /// output is a `========` banner ("System Update via Topgrade") that is
    /// *not* a summary block. `process_line` must not treat it as one --
    /// no bogus `Summary` event, and the post-summary watchdog deadline must
    /// stay unarmed until the real summary block (opened by a `========`
    /// line immediately followed by "  Summary  (duration: ...)") closes.
    #[test]
    fn banner_separator_does_not_arm_watchdog_or_open_summary() {
        let (tx, rx) = mpsc::channel::<AppEvent>();
        let ctx = egui::Context::default();
        let mut state = SummaryState::default();

        // The real bat's opening banner plus a bit of normal output.
        let banner_and_prelude = [
            "",
            "========================================",
            "  System Update via Topgrade",
            "========================================",
            "",
            "[setup] winget not found. Trying to register App Installer...",
            "",
        ];
        for line in banner_and_prelude {
            process_line(line, false, &tx, &ctx, &mut state);
        }
        assert!(!state.in_summary, "banner falsely opened a summary block");
        assert!(
            state.summary_deadline.is_none(),
            "banner falsely armed the post-summary watchdog"
        );
        assert!(state.pending_open.is_none());

        // The real end-of-run summary block, verbatim as emitted by the bat.
        let real_summary_block = [
            "========================================",
            "  Summary  (duration: 00:12:34)",
            "----------------------------------------",
            "  winget          : ok",
            "  topgrade        : ok",
            "  Windows Update  : skipped",
            "  Store           : ok",
            "  Steam games     : ok",
            "  JDownloader     : skipped",
            "  EA app          : n/a",
            "----------------------------------------",
            "  Log: C:\\Users\\me\\Documents\\SystemUpdateLogs\\Topgrade_20260101_010101.log",
            "========================================",
        ];
        for line in real_summary_block {
            process_line(line, false, &tx, &ctx, &mut state);
        }
        assert!(!state.in_summary);
        assert!(state.pending_open.is_none());
        assert!(
            state.summary_deadline.is_some(),
            "watchdog should arm only after the real summary block closes"
        );

        let total_lines = banner_and_prelude.len() + real_summary_block.len();
        let events: Vec<AppEvent> = rx.try_iter().collect();

        let log_lines = events
            .iter()
            .filter(|e| matches!(e, AppEvent::LogLine(_)))
            .count();
        assert_eq!(
            log_lines, total_lines,
            "every raw line should still reach the log pane, including the banner"
        );

        let summaries: Vec<&SummaryData> = events
            .iter()
            .filter_map(|e| match e {
                AppEvent::Summary(d) => Some(d),
                _ => None,
            })
            .collect();
        assert_eq!(
            summaries.len(),
            1,
            "expected exactly one Summary event (the real block, not the banner)"
        );
        assert_eq!(summaries[0].duration.as_deref(), Some("00:12:34"));
        assert_eq!(summaries[0].winget.as_deref(), Some("ok"));
        assert_eq!(summaries[0].windows_update.as_deref(), Some("skipped"));
        assert!(!summaries[0].is_empty());
    }

    #[test]
    fn summary_data_is_empty_detects_all_none() {
        assert!(SummaryData::default().is_empty());
        let data = SummaryData {
            winget: Some("ok".to_string()),
            ..Default::default()
        };
        assert!(!data.is_empty());
    }

    #[test]
    fn category_from_tag_maps_known_tags() {
        assert_eq!(
            category_from_tag("[winupdate] doing stuff"),
            Some(Category::WindowsUpdate)
        );
        assert_eq!(
            category_from_tag("[store] doing stuff"),
            Some(Category::Store)
        );
        assert_eq!(
            category_from_tag("[steam] doing stuff"),
            Some(Category::Steam)
        );
        assert_eq!(
            category_from_tag("[winget] doing stuff"),
            Some(Category::Apps)
        );
        assert_eq!(category_from_tag("no tag here"), None);
    }
}
