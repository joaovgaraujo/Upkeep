//! Live, timestamped transcript of an update run.
//!
//! The bat's own `Topgrade_*.log` only receives what individual steps append,
//! and several steps used to append only when they finished -- a run stopped
//! mid-way (or a window closed during a 20-minute installer) left no log at
//! all. This writes every line the engine prints, as it arrives, to
//! `Documents\SystemUpdateLogs\Upkeep_<date>_<time>.log`, flushing each line,
//! so whatever happened up to the last second is on disk.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

/// Keep this many session logs; older ones are deleted when a run starts
/// (the bat applies the same limit to its `Topgrade_*.log` files).
const KEEP: usize = 20;
const PREFIX: &str = "Upkeep_";

/// Local wall-clock time, down to the second.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LocalTime {
    pub year: u16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub second: u16,
}

impl LocalTime {
    pub fn now() -> Self {
        #[cfg(windows)]
        {
            #[repr(C)]
            struct SystemTime {
                year: u16,
                month: u16,
                day_of_week: u16,
                day: u16,
                hour: u16,
                minute: u16,
                second: u16,
                milliseconds: u16,
            }
            #[link(name = "kernel32")]
            extern "system" {
                fn GetLocalTime(out: *mut SystemTime);
            }
            let mut st = SystemTime {
                year: 0,
                month: 0,
                day_of_week: 0,
                day: 0,
                hour: 0,
                minute: 0,
                second: 0,
                milliseconds: 0,
            };
            // SAFETY: GetLocalTime only writes the SYSTEMTIME struct it is
            // given, which is a valid, correctly laid out #[repr(C)] local.
            unsafe { GetLocalTime(&mut st) };
            LocalTime {
                year: st.year,
                month: st.month,
                day: st.day,
                hour: st.hour,
                minute: st.minute,
                second: st.second,
            }
        }
        #[cfg(not(windows))]
        {
            // Tests on other hosts only need a stable shape, not the zone.
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let day_secs = secs % 86_400;
            LocalTime {
                year: 1970,
                month: 1,
                day: 1,
                hour: (day_secs / 3600) as u16,
                minute: (day_secs % 3600 / 60) as u16,
                second: (day_secs % 60) as u16,
            }
        }
    }

    /// `20261005_174530`, sortable, matching the bat's log naming.
    pub fn stamp(&self) -> String {
        format!(
            "{:04}{:02}{:02}_{:02}{:02}{:02}",
            self.year, self.month, self.day, self.hour, self.minute, self.second
        )
    }

    /// `17:45:30`
    pub fn clock(&self) -> String {
        format!("{:02}:{:02}:{:02}", self.hour, self.minute, self.second)
    }
}

pub struct SessionLog {
    file: File,
    path: PathBuf,
}

impl SessionLog {
    /// Opens a new session log under `%USERPROFILE%\Documents\SystemUpdateLogs`
    /// (the folder the bat logs to). `None` if it can't be created -- the run
    /// itself must never fail because of logging.
    pub fn create() -> Option<Self> {
        let profile = std::env::var_os("USERPROFILE")?;
        let dir = Path::new(&profile)
            .join("Documents")
            .join("SystemUpdateLogs");
        Self::create_in(&dir, LocalTime::now())
    }

    pub fn create_in(dir: &Path, now: LocalTime) -> Option<Self> {
        fs::create_dir_all(dir).ok()?;
        prune(dir, KEEP.saturating_sub(1));
        let path = dir.join(format!("{PREFIX}{}.log", now.stamp()));
        let file = File::create(&path).ok()?;
        Some(SessionLog { file, path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Appends `[HH:MM:SS] line` and flushes, so a killed run keeps it.
    pub fn line(&mut self, line: &str) {
        self.line_at(LocalTime::now(), line);
    }

    pub fn line_at(&mut self, now: LocalTime, line: &str) {
        let _ = writeln!(self.file, "[{}] {line}", now.clock());
        let _ = self.file.flush();
    }
}

/// Deletes all but the newest `keep` session logs in `dir`. Names embed a
/// sortable timestamp, so name order is age order.
fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut logs: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(PREFIX) && n.ends_with(".log"))
        })
        .collect();
    logs.sort();
    let excess = logs.len().saturating_sub(keep);
    for old in &logs[..excess] {
        let _ = fs::remove_file(old);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(hour: u16, minute: u16, second: u16) -> LocalTime {
        LocalTime {
            year: 2026,
            month: 10,
            day: 5,
            hour,
            minute,
            second,
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("upkeep-session-log-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn formats_sortable_stamp_and_clock() {
        let t = at(7, 5, 9);
        assert_eq!(t.stamp(), "20261005_070509");
        assert_eq!(t.clock(), "07:05:09");
    }

    #[test]
    fn writes_each_line_immediately_with_timestamp() {
        let dir = temp_dir("write");
        let mut log = SessionLog::create_in(&dir, at(17, 45, 30)).unwrap();
        assert!(log.path().ends_with("Upkeep_20261005_174530.log"));
        log.line_at(at(17, 45, 31), "[winget] (1/2) Fixture.App 1 -> 2...");
        // Read back while the writer is still open: nothing may be buffered.
        let text = fs::read_to_string(log.path()).unwrap();
        assert_eq!(text, "[17:45:31] [winget] (1/2) Fixture.App 1 -> 2...\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn keeps_only_the_newest_logs_and_ignores_other_files() {
        let dir = temp_dir("prune");
        fs::create_dir_all(&dir).unwrap();
        for i in 0..25 {
            fs::write(dir.join(format!("Upkeep_20260101_0000{i:02}.log")), "").unwrap();
        }
        fs::write(dir.join("Topgrade_20260101_000000.log"), "").unwrap();
        let log = SessionLog::create_in(&dir, at(23, 0, 0)).unwrap();
        let mut names: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        let sessions: Vec<_> = names.iter().filter(|n| n.starts_with(PREFIX)).collect();
        assert_eq!(sessions.len(), KEEP);
        assert!(names.contains(&"Topgrade_20260101_000000.log".to_string()));
        assert!(!names.contains(&"Upkeep_20260101_000000.log".to_string()));
        assert!(log.path().exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
