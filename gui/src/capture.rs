//! Developer capture mode: `UPKEEP_CAPTURE=<folder>` opens each page in turn,
//! saves a screenshot of it as `<nn>-<page>.bmp` in that folder, and closes
//! the app. Used to review the UI and to refresh README screenshots.
//! `UPKEEP_CAPTURE_THEME=light|dark` picks the theme. Nothing runs, nothing
//! is changed: pages are only drawn.
//!
//! BMP because the crate deliberately has no image encoder (see Cargo.toml).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long a page is shown before it is captured, so background loads
/// (startup entries, services, the app catalog) have drawn.
const SETTLE: Duration = Duration::from_millis(2500);

pub struct Capture {
    dir: PathBuf,
    shots: Vec<&'static str>,
    index: usize,
    shown_at: Option<Instant>,
    requested: bool,
}

impl Capture {
    pub fn from_env() -> Option<Self> {
        let dir = std::env::var_os("UPKEEP_CAPTURE")?;
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).ok()?;
        Some(Self {
            dir,
            shots: vec![
                "update", "install", "newpc", "optimize", "startup", "tasks", "services", "tools",
                "log", "summary", "pins", "drivers",
            ],
            index: 0,
            shown_at: None,
            requested: false,
        })
    }

    pub fn theme() -> Option<String> {
        std::env::var("UPKEEP_CAPTURE_THEME").ok()
    }

    /// The shot to show now, or None when all are saved.
    pub fn current(&self) -> Option<&'static str> {
        self.shots.get(self.index).copied()
    }

    /// Call once per frame after drawing. Returns true when every shot is saved.
    pub fn step(&mut self, ctx: &egui::Context) -> bool {
        let Some(name) = self.current() else {
            return true;
        };
        ctx.request_repaint_after(Duration::from_millis(100));
        let shown = *self.shown_at.get_or_insert_with(Instant::now);
        if !self.requested {
            if shown.elapsed() >= SETTLE {
                ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(Default::default()));
                self.requested = true;
            }
            return false;
        }
        let image = ctx.input(|i| {
            i.raw.events.iter().find_map(|e| match e {
                egui::Event::Screenshot { image, .. } => Some(image.clone()),
                _ => None,
            })
        });
        if let Some(image) = image {
            let path = self.dir.join(format!("{:02}-{name}.bmp", self.index + 1));
            let _ = write_bmp(&path, &image);
            self.index += 1;
            self.shown_at = None;
            self.requested = false;
        }
        self.current().is_none()
    }
}

/// 32-bit top-down BMP.
fn write_bmp(path: &Path, image: &egui::ColorImage) -> std::io::Result<()> {
    let [w, h] = image.size;
    let data_len = (w * h * 4) as u32;
    let mut out = Vec::with_capacity(54 + data_len as usize);
    out.extend_from_slice(b"BM");
    out.extend_from_slice(&(54 + data_len).to_le_bytes());
    out.extend_from_slice(&[0u8; 4]);
    out.extend_from_slice(&54u32.to_le_bytes());
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(w as i32).to_le_bytes());
    out.extend_from_slice(&(-(h as i32)).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&data_len.to_le_bytes());
    out.extend_from_slice(&[0u8; 16]);
    for p in &image.pixels {
        out.extend_from_slice(&[p.b(), p.g(), p.r(), 255]);
    }
    std::fs::write(path, out)
}
