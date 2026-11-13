//! Run progress as a share of time: elapsed / (elapsed + expected remaining).
//!
//! The run goes through phases in a fixed order, each announced by the first
//! engine line with its `[tag]`. How long each phase takes is learned from
//! the last completed runs (the timestamps in `Upkeep_*.log`), so the bar
//! moves at the pace this PC actually runs at. The winget phase scales with
//! the number of packages pending and counts down as each one finishes.
//!
//! Before, phases had fixed weights, winget's package counter was never read
//! (its lines start with `[winget]`, the parser wanted `(i/n)` first), and
//! between phases the bar eased to the phase's end within a minute and then
//! sat there: in an hour-long run it showed the same number for most of it.

use regex::Regex;
use std::collections::HashMap;
use std::path::Path;
use std::sync::LazyLock;

/// Serial-lane phases in the order the engine runs them. Steps that don't
/// run for a selection are skipped over when a later tag shows up.
const SERIAL: [&str; 8] = [
    "setup",
    "winget",
    "ai-cli",
    "topgrade",
    "skills",
    "winupdate",
    "featureupdate",
    "nvidia",
];

/// Seconds, when no earlier run says otherwise.
fn default_secs(tag: &str) -> f32 {
    match tag {
        "setup" => 12.0,
        "winget" => 120.0,
        "ai-cli" => 30.0,
        "topgrade" => 60.0,
        "skills" => 20.0,
        "winupdate" => 60.0,
        "featureupdate" => 15.0,
        "nvidia" => 5.0,
        "clients" => 120.0,
        _ => 30.0,
    }
}
const DEFAULT_SECS_PER_PACKAGE: f32 = 25.0;
/// winget's own scan and set-up before the first install.
const WINGET_BASE_SECS: f32 = 15.0;

static STAMP_TAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[(\d\d):(\d\d):(\d\d)\]\s*(?:\[([A-Za-z0-9_-]+)\])?").unwrap());
static PENDING_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\d+) package\(s\) have upgrades available").unwrap());
static FINISHED_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*\[winget\]\s*\((\d+)/(\d+)\)\s+\S+\s+finished in").unwrap());

/// The phase a tagged engine line starts, if any. The quick topgrade steps
/// announce themselves during winget; that is not the topgrade phase.
fn phase_tag(line: &str) -> Option<&str> {
    let t = line.trim_start();
    let rest = t.strip_prefix('[')?;
    let tag = &rest[..rest.find(']')?];
    if tag == "topgrade" && line.contains("alongside winget") {
        return None;
    }
    Some(tag)
}

/// What one completed run took, per phase.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RunTimes {
    pub phase_secs: HashMap<String, f32>,
    pub winget_packages: Option<u32>,
}

/// Reads a session log (`[HH:MM:SS] line`). Only a run the engine finished
/// counts; a stopped run's last phase never ended.
pub fn learn(text: &str) -> Option<RunTimes> {
    if !text.contains("Update process exited with code") {
        return None;
    }
    let mut starts: Vec<(&'static str, f32)> = Vec::new();
    let mut next = 0usize;
    let mut last = None::<f32>;
    let mut day = 0.0_f32;
    let mut prev_clock = None::<f32>;
    let mut packages = None;
    for line in text.lines() {
        let Some(c) = STAMP_TAG_RE.captures(line) else {
            continue;
        };
        let clock = c[1].parse::<f32>().ok()? * 3600.0
            + c[2].parse::<f32>().ok()? * 60.0
            + c[3].parse::<f32>().ok()?;
        if prev_clock.is_some_and(|p| clock + 3600.0 < p) {
            day += 86400.0; // past midnight
        }
        prev_clock = Some(clock);
        let t = clock + day;
        last = Some(t);
        if packages.is_none() {
            if let Some(p) = PENDING_RE.captures(line) {
                packages = p[1].parse().ok();
            }
        }
        // The line after its timestamp.
        let body = line.split_once(']').map_or("", |x| x.1);
        let Some(tag) = phase_tag(body) else { continue };
        if let Some(pos) = SERIAL[next..].iter().position(|p| *p == tag) {
            starts.push((SERIAL[next + pos], t));
            next += pos + 1;
        }
    }
    let end = last?;
    let mut phase_secs = HashMap::new();
    for (i, (tag, start)) in starts.iter().enumerate() {
        let stop = starts.get(i + 1).map_or(end, |(_, s)| *s);
        phase_secs.insert((*tag).to_string(), (stop - start).max(0.0));
    }
    Some(RunTimes {
        phase_secs,
        winget_packages: packages,
    })
}

/// Typical phase lengths from earlier runs.
#[derive(Debug, Default, Clone)]
pub struct History {
    runs: Vec<RunTimes>,
}

fn median(mut v: Vec<f32>) -> Option<f32> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    Some(v[v.len() / 2])
}

impl History {
    pub fn from_runs(runs: Vec<RunTimes>) -> Self {
        Self { runs }
    }

    /// The last `max` completed runs in `dir` (newest first by name, which
    /// carries the date and time).
    pub fn load(dir: &Path, max: usize) -> Self {
        let mut names: Vec<_> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("Upkeep_") && n.ends_with(".log"))
            })
            .collect();
        names.sort();
        names.reverse();
        let runs = names
            .iter()
            .take(max * 3)
            .filter_map(|p| std::fs::read_to_string(p).ok())
            .filter_map(|t| learn(&t))
            .take(max)
            .collect();
        Self { runs }
    }

    fn phase(&self, tag: &str) -> Option<f32> {
        median(
            self.runs
                .iter()
                .filter_map(|r| r.phase_secs.get(tag).copied())
                .collect(),
        )
    }

    fn secs_per_package(&self) -> f32 {
        median(
            self.runs
                .iter()
                .filter_map(|r| {
                    let n = r.winget_packages.filter(|n| *n > 0)? as f32;
                    Some(((r.phase_secs.get("winget")? - WINGET_BASE_SECS) / n).max(2.0))
                })
                .collect(),
        )
        .unwrap_or(DEFAULT_SECS_PER_PACKAGE)
    }
}

#[derive(Debug, Clone)]
struct Phase {
    tag: &'static str,
    expected: f32,
}

/// Follows one run. Times are seconds since the run started.
#[derive(Debug, Clone)]
pub struct Tracker {
    phases: Vec<Phase>,
    idx: usize,
    phase_start: f32,
    secs_per_package: f32,
    winget_total: Option<u32>,
    winget_done: u32,
    shown: f32,
    finished: bool,
}

impl Tracker {
    /// Phases for the checked categories. The client lane (Store, Steam,
    /// JDownloader, G HUB, RustDesk) overlaps the serial lane; it only gets a
    /// phase when it is the whole run.
    pub fn new(
        history: &History,
        wu: bool,
        feature: bool,
        store: bool,
        apps: bool,
        steam: bool,
    ) -> Self {
        let mut tags: Vec<&'static str> = vec!["setup"];
        if apps {
            tags.extend(["winget", "ai-cli", "topgrade", "skills"]);
        }
        if wu {
            tags.push("winupdate");
        }
        if feature {
            tags.push("featureupdate");
        }
        if apps {
            tags.push("nvidia");
        }
        if (store || steam) && !(apps || wu || feature) {
            tags.push("clients");
        }
        let phases = tags
            .into_iter()
            .map(|tag| Phase {
                tag,
                expected: history
                    .phase(tag)
                    .unwrap_or_else(|| default_secs(tag))
                    .max(2.0),
            })
            .collect();
        Self {
            phases,
            idx: 0,
            phase_start: 0.0,
            secs_per_package: history.secs_per_package(),
            winget_total: None,
            winget_done: 0,
            shown: 0.0,
            finished: false,
        }
    }

    pub fn phase(&self) -> &'static str {
        self.phases.get(self.idx).map_or("", |p| p.tag)
    }

    /// Feeds one engine output line.
    pub fn on_line(&mut self, line: &str, now: f32) {
        if let Some(c) = FINISHED_RE.captures(line) {
            self.winget_done = self.winget_done.max(c[1].parse().unwrap_or(0));
            if let Ok(n) = c[2].parse::<u32>() {
                self.winget_total = Some(n);
            }
        } else if let Some(c) = PENDING_RE.captures(line) {
            if let Ok(n) = c[1].parse::<u32>() {
                self.winget_total = Some(n);
                if let Some(p) = self.phases.iter_mut().find(|p| p.tag == "winget") {
                    p.expected = WINGET_BASE_SECS + n as f32 * self.secs_per_package;
                }
            }
        }
        let Some(tag) = phase_tag(line) else { return };
        let tag = if matches!(tag, "store" | "steam" | "jdownloader") {
            "clients"
        } else {
            tag
        };
        if let Some(pos) = self.phases[self.idx..].iter().position(|p| p.tag == tag) {
            if pos > 0 {
                self.idx += pos;
                self.phase_start = now;
            }
        }
    }

    /// Seconds the run probably still needs.
    pub fn remaining(&self, now: f32) -> f32 {
        if self.finished {
            return 0.0;
        }
        let Some(cur) = self.phases.get(self.idx) else {
            return 0.0;
        };
        let in_phase = (now - self.phase_start).max(0.0);
        let current = match (cur.tag, self.winget_total) {
            ("winget", Some(n)) => {
                let left = n.saturating_sub(self.winget_done) as f32;
                // A package still installing after its share keeps a little time.
                (WINGET_BASE_SECS + n as f32 * self.secs_per_package - in_phase)
                    .min(left * self.secs_per_package)
                    .max(left.min(1.0) * 0.15 * self.secs_per_package)
                    .max(3.0)
            }
            // Past its usual length the phase keeps a slice of it, so the
            // bar slows down instead of stopping.
            _ => (cur.expected - in_phase).max(cur.expected * 0.15).max(3.0),
        };
        current
            + self.phases[self.idx + 1..]
                .iter()
                .map(|p| p.expected)
                .sum::<f32>()
    }

    /// 0.0-1.0 for the bar; never goes back.
    pub fn fraction(&mut self, now: f32) -> f32 {
        if self.finished {
            return 1.0;
        }
        let r = self.remaining(now);
        let f = if now <= 0.0 { 0.0 } else { now / (now + r) };
        self.shown = self.shown.max(f.min(0.99));
        self.shown
    }

    /// The engine printed its summary.
    pub fn summary_seen(&mut self) {
        self.shown = self.shown.max(0.99);
    }

    pub fn finish(&mut self) {
        self.finished = true;
        self.shown = 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOG: &str = "\
[10:00:00] [setup] winget OK
[10:00:05] [run] Starting topgrade.
[10:00:10] [winget] Checking for pending upgrades...
[10:00:12] [winget] 4 package(s) have upgrades available.
[10:00:13] [topgrade] Running rustup alongside winget.
[10:01:00] [winget] (1/4) A finished in 40s (exit 0).
[10:02:10] [ai-cli] Checking
[10:02:40] [topgrade] Starting
[10:03:40] [skills] x
[10:04:00] [winupdate] y
[10:05:00] [featureupdate] z
[10:05:10] [nvidia] n
[10:05:15] [engine] Update process exited with code 0.
";

    #[test]
    fn learns_phase_lengths_from_a_finished_run() {
        let r = learn(LOG).unwrap();
        assert_eq!(r.phase_secs["setup"], 10.0);
        // The quick topgrade line during winget does not end winget.
        assert_eq!(r.phase_secs["winget"], 120.0);
        assert_eq!(r.phase_secs["ai-cli"], 30.0);
        assert_eq!(r.phase_secs["topgrade"], 60.0);
        assert_eq!(r.phase_secs["nvidia"], 5.0);
        assert_eq!(r.winget_packages, Some(4));
    }

    #[test]
    fn ignores_a_stopped_run() {
        assert!(
            learn(&LOG.replace("Update process exited with code 0.", "Stop requested")).is_none()
        );
    }

    #[test]
    fn crosses_midnight() {
        let log = "[23:59:50] [setup] a\n[00:00:20] [winget] b\n[00:01:00] [engine] Update process exited with code 0.\n";
        let r = learn(log).unwrap();
        assert_eq!(r.phase_secs["setup"], 30.0);
        assert_eq!(r.phase_secs["winget"], 40.0);
    }

    fn tracker() -> Tracker {
        let h = History::from_runs(vec![learn(LOG).unwrap()]);
        Tracker::new(&h, true, true, true, true, true)
    }

    #[test]
    fn moves_with_time_and_never_goes_back() {
        let mut t = tracker();
        let a = t.fraction(1.0);
        let b = t.fraction(5.0);
        assert!(b > a, "{a} {b}");
        t.on_line("[winget] Checking for pending upgrades...", 10.0);
        let c = t.fraction(10.0);
        assert!(c >= b);
        // Many more packages than last time: the estimate grows, the bar holds.
        t.on_line("[winget] 40 package(s) have upgrades available.", 12.0);
        assert!(t.fraction(12.0) >= c);
        assert!(t.remaining(12.0) > 600.0);
    }

    #[test]
    fn counts_winget_packages_down() {
        let mut t = tracker();
        t.on_line("[winget] Checking", 10.0);
        t.on_line("[winget] 10 package(s) have upgrades available.", 11.0);
        let before = t.remaining(20.0);
        for i in 1..=5 {
            t.on_line(
                &format!("[winget] ({i}/10) Pkg.{i} finished in 3s (exit 0)."),
                20.0,
            );
        }
        let after = t.remaining(20.0);
        assert!(after < before, "{before} -> {after}");
    }

    #[test]
    fn a_long_phase_slows_the_bar_but_does_not_stop_it() {
        let mut t = tracker();
        t.on_line("[winget] Checking", 10.0);
        let x = t.fraction(2000.0);
        let y = t.fraction(4000.0);
        assert!(y > x && y < 0.99, "{x} {y}");
    }

    #[test]
    fn skips_phases_that_did_not_run() {
        let mut t = tracker();
        t.on_line("[winupdate] Checking", 50.0);
        assert_eq!(t.phase(), "winupdate");
        // An earlier phase's tag later on does not move it back.
        t.on_line("[winget] late line", 60.0);
        assert_eq!(t.phase(), "winupdate");
    }

    #[test]
    fn clients_only_run_has_its_own_phase() {
        let mut t = Tracker::new(&History::default(), false, false, true, false, true);
        t.on_line("[store] Triggering", 3.0);
        assert_eq!(t.phase(), "clients");
        t.finish();
        assert_eq!(t.fraction(4.0), 1.0);
    }
}
