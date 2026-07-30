//! Library crate for the UpdateAll Dashboard. Kept separate from the `bin`
//! target (see `main.rs`) so `cargo test` builds a plain lib test harness
//! that does *not* inherit the `requireAdministrator` manifest embedded into
//! the real executable by `build.rs` — that manifest only applies to `[[bin]]`
//! targets, so keeping the actual logic here lets tests run unelevated.

pub mod advice;
pub mod app;
pub mod drivers;
pub mod engine;
pub mod i18n;
pub mod optimize;
pub mod pins;
pub mod reboot;
pub mod settings;
pub mod system;
pub mod theme;
