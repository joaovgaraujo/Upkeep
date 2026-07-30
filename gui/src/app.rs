use crate::advice::{self, Advice};
use crate::drivers::{self, DriverEntry};
use crate::engine::{self, AppEvent, Category, EngineExit, SkipFlags, Status, SummaryData};
use crate::i18n::{self, Lang, Strings};
use crate::optimize;
use crate::pins::{self, Manager, PinEntry};
use crate::reboot::{self, RebootFlags};
use crate::settings::{self, Settings};
use crate::system::{self, InstalledApp, ServiceEntry, StartupEntry, TaskEntry};
use crate::theme::{self, ThemeChoice};

use eframe::egui;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const MAX_LOG_LINES: usize = 10_000;

/// Top-level pages, ordered by how often a non-technical user needs them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Page {
    Update,
    Install,
    NewPc,
    Optimize,
    System,
    Tools,
    Advanced,
}

/// Sub-tabs inside the Advanced page (the old power-user surface).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tab {
    Log,
    Summary,
    Pins,
    DriverStore,
}

/// The two halves of the Startup & Services page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SystemSection {
    Startup,
    Tasks,
    Services,
}

/// Sortable columns shared by the Startup / Tasks / Services tables (each
/// table uses the subset that applies to it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SortField {
    Status,
    Advice,
    Name,
    Display,
    Time,
    StartMode,
}

/// Current sort of one table: which column, and which direction.
#[derive(Debug, Clone, Copy)]
struct TableSort {
    field: SortField,
    asc: bool,
}

impl TableSort {
    /// Default: enabled/running items first, alphabetical inside groups.
    fn on_first() -> Self {
        TableSort {
            field: SortField::Status,
            asc: true,
        }
    }

    /// Header click: same column flips direction, new column selects it
    /// (Time starts descending — the slow items are what you look for).
    fn click(&mut self, field: SortField) {
        if self.field == field {
            self.asc = !self.asc;
        } else {
            self.field = field;
            self.asc = field != SortField::Time;
        }
    }

    fn arrow(&self, field: SortField) -> &'static str {
        if self.field != field {
            ""
        } else if self.asc {
            " \u{25B2}"
        } else {
            " \u{25BC}"
        }
    }
}

pub struct DashboardApp {
    root: Option<PathBuf>,
    bat_path: Option<PathBuf>,
    settings: Settings,
    lang: Lang,
    theme_choice: ThemeChoice,
    ui_scale: f32,

    tx: Sender<AppEvent>,
    rx: Receiver<AppEvent>,

    cat_windows_update: bool,
    cat_store: bool,
    cat_apps: bool,
    cat_steam: bool,

    status: HashMap<Category, Status>,

    is_running: bool,
    run_start: Option<Instant>,
    last_output: Option<Instant>,

    // Run progress estimate (0-100), driven by [tag] milestones plus
    // intra-phase hints; creeps asymptotically toward the current phase
    // ceiling between markers so the bar never looks frozen.
    progress: f32,
    progress_ceiling: f32,
    milestones: Vec<Milestone>,
    milestone_idx: usize,

    // Bundle chooser (preset app list with per-app selection)
    bundle_preset: Option<String>,
    bundle_apps: Vec<BundleApp>,

    log_lines: VecDeque<String>,

    summary: Option<SummaryData>,
    engine_exit: Option<EngineExit>,
    toast_sent: bool,

    reboot: RebootFlags,
    show_reboot_confirm: bool,

    page: Page,
    active_tab: Tab,

    pins: Vec<PinEntry>,
    new_pin_id: String,
    new_pin_manager: Manager,
    pin_error: Option<String>,
    pin_save_msg: Option<String>,

    drivers: Vec<DriverEntry>,
    drivers_loading: bool,
    drivers_error: Option<String>,

    nvclean_help_open: bool,

    // New PC page: which setup phases run.
    newpc_restore: bool,
    newpc_tweaks: bool,
    newpc_toggles: bool,
    newpc_drivers: bool,
    newpc_oosu: bool,
    newpc_apps: bool,

    // Optimize page: parallel selection flags for optimize::TWEAKS/TOGGLES.
    opt_tweaks: Vec<bool>,
    opt_toggles: Vec<bool>,
    opt_oosu: bool,
    /// OOSU mode shared by both pages: true = silent recommended config,
    /// false = open the program for a manual pick.
    opt_oosu_auto: bool,

    // Pin picker: installed packages detected via winget/choco.
    installed_apps: Vec<InstalledApp>,
    installed_loading: bool,
    pin_filter: String,

    // Startup & Services page (lazy-loaded on first open).
    system_section: SystemSection,
    services: Vec<ServiceEntry>,
    services_loading: bool,
    services_fetched: bool,
    services_error: Option<String>,
    services_filter: String,
    /// A Set-Service change in flight (service name), disabling the combos.
    service_busy: Option<String>,
    autostart_entries: Vec<StartupEntry>,
    autostart_loading: bool,
    autostart_fetched: bool,
    autostart_error: Option<String>,
    autostart_filter: String,
    autostart_sort: TableSort,
    /// A startup toggle in flight (entry name), disabling the buttons.
    autostart_busy: Option<String>,
    tasks_sort: TableSort,
    services_sort: TableSort,
    /// Advanced mode: also show the items marked "keep" (and, for services,
    /// the unidentified ones) that are best left alone.
    system_show_advanced: bool,
    /// Measured per-item startup times (boot-times.json), name -> seconds.
    boot_times: std::collections::HashMap<String, f64>,
    tasks: Vec<TaskEntry>,
    tasks_loading: bool,
    tasks_fetched: bool,
    tasks_error: Option<String>,
    tasks_filter: String,
    /// A scheduled-task toggle in flight (task name).
    tasks_busy: Option<String>,

    /// Discovered preset packs: (slug, app count).
    presets: Vec<(String, usize)>,

    /// Set to true to ask the running engine to stop. `None` when idle.
    engine_stop: Option<Arc<AtomicBool>>,
    /// Set by the engine thread once it has fully finished, so window
    /// close can wait a bounded time instead of orphaning the run.
    engine_finished: Option<Arc<AtomicBool>>,

    last_error: Option<String>,
    startup_error: Option<String>,
}

impl DashboardApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        theme::apply(&cc.egui_ctx);

        let root = settings::resolve_root();
        let bat_path = root.as_ref().map(|r| r.join(settings::BAT_NAME));
        let mut settings = root
            .as_ref()
            .map(|r| settings::load_settings(r))
            .unwrap_or_default();
        // Heal an out-of-range hand-edited "UiScale" before the save below,
        // so it isn't re-emitted verbatim by this and every later save.
        settings.ui_scale = theme::clamp_scale(settings.ui_scale);
        // Persist so the settings file always exists with the current
        // (possibly autodiscovered) defaults, matching the PS dashboard.
        if let Some(r) = &root {
            let _ = settings::save_settings(r, &settings);
        }

        let pins = bat_path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|text| pins::parse_pins(&text))
            .unwrap_or_default();

        let presets = root
            .as_ref()
            .map(|r| discover_presets(&r.join("presets")))
            .unwrap_or_default();

        // The full catalog is visible from the start (nothing pre-checked);
        // pack cards only change the initial checkmarks. A missing/broken
        // apps.json degrades to an empty list and is reported on the page.
        let bundle_apps = root
            .as_ref()
            .and_then(|r| load_bundle(r, None).ok())
            .unwrap_or_default();

        let mut status = HashMap::new();
        for cat in [
            Category::WindowsUpdate,
            Category::Store,
            Category::Apps,
            Category::Steam,
            Category::Drivers,
        ] {
            status.insert(cat, Status::Idle);
        }

        let (tx, rx) = std::sync::mpsc::channel();

        let boot_times = root
            .as_ref()
            .map(|r| system::load_boot_times(r))
            .unwrap_or_default();

        let lang = Lang::from_code(&settings.language);
        let theme_choice = ThemeChoice::from_code(&settings.theme);
        theme::set_choice(&cc.egui_ctx, theme_choice);
        let ui_scale = settings.ui_scale;
        theme::set_scale(&cc.egui_ctx, ui_scale);

        let startup_error = if root.is_none() {
            Some(i18n::startup_error(lang, settings::BAT_NAME))
        } else {
            None
        };

        Self {
            root,
            bat_path,
            settings,
            lang,
            theme_choice,
            ui_scale,
            tx,
            rx,
            cat_windows_update: true,
            cat_store: true,
            cat_apps: true,
            cat_steam: true,
            status,
            is_running: false,
            run_start: None,
            last_output: None,
            progress: 0.0,
            progress_ceiling: 0.0,
            milestones: Vec::new(),
            milestone_idx: 0,
            bundle_preset: None,
            bundle_apps,
            log_lines: VecDeque::new(),
            summary: None,
            engine_exit: None,
            toast_sent: false,
            reboot: reboot::check_pending_reboot(),
            show_reboot_confirm: false,
            page: Page::Update,
            active_tab: Tab::Log,
            pins,
            new_pin_id: String::new(),
            new_pin_manager: Manager::Winget,
            pin_error: None,
            pin_save_msg: None,
            drivers: Vec::new(),
            drivers_loading: false,
            drivers_error: None,
            nvclean_help_open: false,
            newpc_restore: true,
            newpc_tweaks: true,
            newpc_toggles: true,
            newpc_drivers: true,
            newpc_oosu: true,
            newpc_apps: true,
            opt_tweaks: optimize::TWEAKS.iter().map(|t| t.default_on).collect(),
            opt_toggles: optimize::TOGGLES.iter().map(|t| t.default_on).collect(),
            opt_oosu: true,
            opt_oosu_auto: true,
            installed_apps: Vec::new(),
            installed_loading: false,
            pin_filter: String::new(),
            system_section: SystemSection::Startup,
            services: Vec::new(),
            services_loading: false,
            services_fetched: false,
            services_error: None,
            services_filter: String::new(),
            service_busy: None,
            autostart_entries: Vec::new(),
            autostart_loading: false,
            autostart_fetched: false,
            autostart_error: None,
            autostart_filter: String::new(),
            autostart_sort: TableSort::on_first(),
            autostart_busy: None,
            tasks_sort: TableSort::on_first(),
            services_sort: TableSort::on_first(),
            system_show_advanced: false,
            boot_times,
            tasks: Vec::new(),
            tasks_loading: false,
            tasks_fetched: false,
            tasks_error: None,
            tasks_filter: String::new(),
            tasks_busy: None,
            presets,
            engine_stop: None,
            engine_finished: None,
            last_error: None,
            startup_error,
        }
    }

    fn tr(&self) -> &'static Strings {
        i18n::tr(self.lang)
    }

    fn set_language(&mut self, lang: Lang) {
        if self.lang == lang {
            return;
        }
        self.lang = lang;
        self.settings.language = lang.code().to_string();
        if let Some(root) = &self.root {
            let _ = settings::save_settings(root, &self.settings);
        }
    }

    fn set_ui_scale(&mut self, ctx: &egui::Context, scale: f32) {
        // Persistence is left to `track_ui_scale`, which sees this change on
        // the next pass exactly as it sees a keyboard zoom.
        theme::set_scale(ctx, theme::clamp_scale(scale));
    }

    /// Mirror egui's zoom factor into `ui_scale` and settings.json.
    ///
    /// egui handles Ctrl+Plus / Ctrl+Minus / Ctrl+0 itself, changing the zoom
    /// behind the app's back. Without this the Text size combo would keep
    /// displaying a stale percentage, and re-picking the value it *thinks* is
    /// current would be a no-op the user can't escape.
    fn track_ui_scale(&mut self, ctx: &egui::Context) {
        let zoom = ctx.zoom_factor();
        if (self.ui_scale - zoom).abs() < f32::EPSILON {
            return;
        }
        // egui's Ctrl+Plus goes up to 5.0, well past what we support. Pull it
        // back into range rather than persisting a value the next launch
        // would silently snap away from.
        let clamped = theme::clamp_scale(zoom);
        if (clamped - zoom).abs() >= f32::EPSILON {
            theme::set_scale(ctx, clamped);
        }
        let zoom = clamped;
        self.ui_scale = zoom;
        self.settings.ui_scale = zoom;
        if let Some(root) = &self.root {
            let _ = settings::save_settings(root, &self.settings);
        }
    }

    fn set_theme(&mut self, ctx: &egui::Context, choice: ThemeChoice) {
        if self.theme_choice == choice {
            return;
        }
        self.theme_choice = choice;
        self.settings.theme = choice.code().to_string();
        theme::set_choice(ctx, choice);
        if let Some(root) = &self.root {
            let _ = settings::save_settings(root, &self.settings);
        }
    }

    fn push_error(&mut self, msg: impl Into<String>) {
        let msg = msg.into();
        self.push_log(format!("[error] {msg}"));
        self.last_error = Some(msg);
    }

    fn push_log(&mut self, line: String) {
        self.log_lines.push_back(line);
        while self.log_lines.len() > MAX_LOG_LINES {
            self.log_lines.pop_front();
        }
    }

    fn drain_events(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                AppEvent::LogLine(line) => {
                    self.advance_progress(&line);
                    self.push_log(line);
                    self.last_output = Some(Instant::now());
                }
                AppEvent::CategoryStatus(cat, status) => {
                    self.status.insert(cat, status);
                }
                AppEvent::Summary(summary) => {
                    // Defensively ignore a summary with every field `None`:
                    // it can't flip any category chip meaningfully, and
                    // treating it as "a summary was received" would corrupt
                    // the end-of-run finalization/status-label logic below.
                    if !summary.is_empty() {
                        self.summary = Some(summary);
                        // Real summary = the run's work is done; only the
                        // bat's trailing countdown remains.
                        self.progress = self.progress.max(99.0);
                        self.progress_ceiling = 100.0;
                    }
                }
                AppEvent::EngineExited(exit) => {
                    self.is_running = false;
                    // The run is over; nothing left to stop or wait on.
                    self.engine_stop = None;
                    self.engine_finished = None;
                    self.engine_exit = Some(exit);
                    // Only fill the bar if the engine actually got far enough
                    // to produce a summary. A spawn failure exiting instantly
                    // used to draw a full 100% bar above the red "engine
                    // produced no summary" banner.
                    if self.summary.is_some() {
                        self.progress = 100.0;
                        self.progress_ceiling = 100.0;
                    }
                    self.finalize_categories();
                    self.send_toast();
                }
                AppEvent::RebootStatus(flags) => {
                    self.reboot = flags;
                }
                AppEvent::DriverList(list) => {
                    self.drivers = list;
                    self.drivers_loading = false;
                    self.drivers_error = None;
                }
                AppEvent::InstalledApps(list) => {
                    self.installed_apps = list;
                    self.installed_loading = false;
                }
                AppEvent::ServiceList(result) => {
                    self.services_loading = false;
                    self.service_busy = None;
                    match result {
                        Ok(list) => {
                            self.services = list;
                            self.services_error = None;
                        }
                        Err(e) => self.services_error = Some(e),
                    }
                }
                AppEvent::StartupList(result) => {
                    self.autostart_loading = false;
                    self.autostart_busy = None;
                    match result {
                        Ok(list) => {
                            self.autostart_entries = list;
                            self.autostart_error = None;
                        }
                        Err(e) => self.autostart_error = Some(e),
                    }
                }
                AppEvent::TaskList(result) => {
                    self.tasks_loading = false;
                    self.tasks_busy = None;
                    match result {
                        Ok(list) => {
                            self.tasks = list;
                            self.tasks_error = None;
                        }
                        Err(e) => self.tasks_error = Some(e),
                    }
                }
                AppEvent::Error(msg) => {
                    // Deliberately NOT attributed to the driver query any
                    // more: `AppEvent::Error` is the generic channel, so an
                    // unrelated failure (a startup toggle, a service change)
                    // arriving while the Driver Store tab happened to be
                    // loading was shown as a driver error and cleared that
                    // tab's spinner. Driver failures report through
                    // `DriverList(Err(..))`.
                    self.push_error(msg);
                }
            }
        }
    }

    /// Called on `AppEvent::EngineExited`. Resolves every checked category's
    /// final status from the parsed summary (if any), then makes sure no
    /// category is left dangling in `Idle`/`Running` -- which would
    /// otherwise happen for a category whose `[tag]` marker fired (flipping
    /// it to `Running`) but that never got a matching summary field, e.g.
    /// because the engine was killed mid-category or died before producing
    /// a summary at all.
    fn finalize_categories(&mut self) {
        let summary_received = self.summary.is_some();

        if let Some(summary) = &self.summary {
            if self.cat_windows_update {
                if let Some(v) = &summary.windows_update {
                    self.status.insert(
                        Category::WindowsUpdate,
                        if summary_value_is_benign(v) { Status::Ok } else { Status::Error },
                    );
                }
            }
            if self.cat_apps {
                let present: Vec<&String> = [
                    &summary.winget,
                    &summary.topgrade,
                    &summary.ea_app,
                    &summary.jdownloader,
                ]
                .into_iter()
                .flatten()
                .collect();
                if !present.is_empty() {
                    let bad = present.iter().any(|v| !summary_value_is_benign(v));
                    self.status
                        .insert(Category::Apps, if bad { Status::Error } else { Status::Ok });
                }
            }
            if self.cat_steam {
                if let Some(v) = &summary.steam {
                    self.status.insert(
                        Category::Steam,
                        if summary_value_is_benign(v) { Status::Ok } else { Status::Error },
                    );
                }
            }
            if self.cat_store {
                if let Some(v) = &summary.store {
                    self.status.insert(
                        Category::Store,
                        if summary_value_is_benign(v) { Status::Ok } else { Status::Error },
                    );
                }
            }
        }

        // Any checked category still unresolved (never touched above,
        // whether it's sitting at `Idle` because it never started, or at
        // `Running` because it started but the engine ended before a
        // matching summary field arrived) needs a final status now.
        //
        // Exit code -1 after a real summary was parsed is the *expected*
        // end of every run (the watchdog kills the bat's trailing
        // `timeout /t 60`), so it counts as a clean exit here just like 0.
        let exit_ok = matches!(self.engine_exit, Some(EngineExit::Code(0)))
            || (summary_received && matches!(self.engine_exit, Some(EngineExit::Stopped)));
        let checks = [
            (self.cat_windows_update, Category::WindowsUpdate),
            (self.cat_store, Category::Store),
            (self.cat_apps, Category::Apps),
            (self.cat_steam, Category::Steam),
        ];
        for (checked, cat) in checks {
            if !checked {
                // An unchecked category still gets a chip drawn for it, and
                // it can have been knocked off "Skipped" mid-run: several
                // Apps-mapped tags ([setup], [pins], [discord], [ea], [run])
                // are emitted unconditionally by the engine, with no
                // knowledge of the skip flags, which flipped Apps to
                // "Running" and left it stuck there. Pin it back to Skipped.
                self.status.insert(cat, Status::Skipped);
                continue;
            }
            let unresolved = matches!(
                self.status.get(&cat).copied().unwrap_or(Status::Idle),
                Status::Idle | Status::Running
            );
            if unresolved {
                let resolved = if !summary_received {
                    // The engine died (or was killed) before ever producing
                    // a summary: we have no evidence this category
                    // succeeded, so treat it as an error rather than idle.
                    Status::Error
                } else if exit_ok {
                    Status::Ok
                } else {
                    Status::Error
                };
                self.status.insert(cat, resolved);
            }
        }
    }

    fn send_toast(&mut self) {
        if self.toast_sent {
            return;
        }
        self.toast_sent = true;

        let t = self.tr();
        let cats: [(bool, &str, Category); 4] = [
            (
                self.cat_windows_update,
                t.cat_windows_update,
                Category::WindowsUpdate,
            ),
            (self.cat_store, t.toast_cat_store, Category::Store),
            (self.cat_apps, t.toast_cat_apps, Category::Apps),
            (
                self.cat_steam,
                t.toast_cat_steam,
                Category::Steam,
            ),
        ];

        let mut all_ok = true;
        let mut lines = Vec::new();
        for (checked, label, cat) in cats {
            if !checked {
                continue;
            }
            let status = self.status.get(&cat).copied().unwrap_or(Status::Idle);
            if status == Status::Error {
                all_ok = false;
            }
            lines.push(format!("{label}: {}", status_label(t, status)));
        }

        if lines.is_empty() {
            return;
        }

        let title = if all_ok {
            t.toast_title_ok
        } else {
            t.toast_title_issues
        };
        let body = lines.join("\n");

        if let Err(e) = notify_rust::Notification::new()
            .summary(title)
            .body(&body)
            .show()
        {
            self.push_error(format!("Toast notification failed: {e}"));
        }
    }

    /// Asks a running engine to stop. Idempotent: safe to call twice, and
    /// safe when nothing is running.
    ///
    /// This only raises a flag. The engine thread notices within one poll of
    /// its 150 ms loop, then kills the process tree and reports
    /// `EngineExit::Stopped` through the normal channel, so the UI settles
    /// exactly as it does for any other end-of-run.
    fn request_stop(&mut self) {
        if let Some(stop) = &self.engine_stop {
            stop.store(true, Ordering::Relaxed);
        }
    }

    /// Blocks (briefly) until the engine thread confirms it has finished.
    ///
    /// Called from `on_exit`, where the alternative is leaving `cmd.exe`,
    /// topgrade, winget and any half-finished installer running headless
    /// with no window and no log.
    ///
    /// The race this has to survive: when the flag is set, the engine thread
    /// is almost certainly parked in `line_rx.recv_timeout(150ms)`, so it
    /// cannot see the flag for up to 150 ms. It then runs `kill_tree` (one
    /// `taskkill` call) and `wait_bounded` (<= KILL_GRACE). That bounds the
    /// real wait at roughly 150 ms + 2 s, so the cap below is generous.
    /// Nothing is joined -- a `JoinHandle::join()` has no timeout and could
    /// hang the close forever, which is precisely the failure being fixed.
    /// If the cap does expire we return anyway: `kill_tree` has already been
    /// issued, so the process tree is dead even if the thread hasn't yet
    /// tidied up. Any `EngineExited` it sends afterwards goes to a dropped
    /// receiver and is discarded by the existing `let _ = tx.send(..)`.
    fn wait_for_engine_stop(&mut self, cap: Duration) {
        let Some(finished) = self.engine_finished.take() else {
            return;
        };
        let deadline = Instant::now() + cap;
        while !finished.load(Ordering::Acquire) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn start_run(&mut self, ctx: &egui::Context, confirmed: bool) {
        self.reboot = reboot::check_pending_reboot();
        if self.reboot.requires_reboot() && !confirmed {
            self.show_reboot_confirm = true;
            return;
        }
        self.show_reboot_confirm = false;

        let invoke_engine =
            self.cat_windows_update || self.cat_store || self.cat_apps || self.cat_steam;

        self.status.insert(
            Category::WindowsUpdate,
            if self.cat_windows_update {
                Status::Idle
            } else {
                Status::Skipped
            },
        );
        self.status.insert(
            Category::Store,
            if self.cat_store {
                Status::Idle
            } else {
                Status::Skipped
            },
        );
        self.status.insert(
            Category::Apps,
            if self.cat_apps {
                Status::Idle
            } else {
                Status::Skipped
            },
        );
        self.status.insert(
            Category::Steam,
            if self.cat_steam {
                Status::Idle
            } else {
                Status::Skipped
            },
        );
        self.summary = None;
        self.engine_exit = None;
        self.toast_sent = false;
        self.last_error = None;

        // Build the progress plan from the checked categories.
        self.milestones = build_milestones(
            self.cat_windows_update,
            self.cat_store,
            self.cat_apps,
            self.cat_steam,
        );
        self.milestone_idx = 0;
        self.progress = 0.0;
        self.progress_ceiling = self.milestones.first().map_or(100.0, |m| m.end);

        if invoke_engine {
            self.log_lines.clear();
            self.is_running = true;
            self.run_start = Some(Instant::now());
            self.last_output = Some(Instant::now());

            let skip = SkipFlags {
                skip_winupdate: !self.cat_windows_update,
                skip_store: !self.cat_store,
                skip_apps: !self.cat_apps,
                skip_steam: !(self.cat_steam),
            };

            if let (Some(bat), Some(root)) = (self.bat_path.clone(), self.root.clone()) {
                let stop = Arc::new(AtomicBool::new(false));
                let finished = Arc::new(AtomicBool::new(false));
                self.engine_stop = Some(Arc::clone(&stop));
                self.engine_finished = Some(Arc::clone(&finished));
                engine::spawn_engine(
                    bat,
                    root,
                    skip,
                    self.tx.clone(),
                    ctx.clone(),
                    stop,
                    finished,
                );
            } else {
                self.push_error("Engine path not resolved; cannot start run.");
                self.is_running = false;
            }
        }
    }

    /// Advances the 0-100 progress estimate from an engine output line.
    /// A `[tag]` matching a milestone at-or-after the current one jumps the
    /// bar to that milestone; a raw winget "(i/n)" counter interpolates
    /// inside the winget phase.
    fn advance_progress(&mut self, line: &str) {
        let (tag, _) = extract_tag(line);
        if let Some(tag) = tag {
            if let Some(j) = self
                .milestones
                .iter()
                .enumerate()
                .skip(self.milestone_idx)
                .find(|(_, m)| m.tag == tag)
                .map(|(j, _)| j)
            {
                let m = &self.milestones[j];
                self.milestone_idx = j;
                self.progress = self.progress.max(m.start);
                self.progress_ceiling = m.end;
            }
            return;
        }

        // Untagged line: winget's own "(i/n) Found ..." counter is the one
        // reliable intra-phase signal.
        if let Some(m) = self.milestones.get(self.milestone_idx) {
            if m.tag == "winget" {
                if let Some((i, n)) = parse_counter(line) {
                    if n > 0 {
                        let frac = (i as f32 / n as f32).clamp(0.0, 1.0);
                        self.progress = self.progress.max(m.start + frac * (m.end - m.start));
                    }
                }
            }
        }
    }

    fn resolve_sdio_exe(&self) -> Option<PathBuf> {
        let dir = &self.settings.sdio_path;
        if dir.is_empty() {
            return None;
        }
        let p = Path::new(dir);
        if p.extension().is_some_and(|e| e.eq_ignore_ascii_case("exe")) && p.is_file() {
            return Some(p.to_path_buf());
        }
        if !p.is_dir() {
            return None;
        }
        let entries: Vec<PathBuf> = std::fs::read_dir(p)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|e| e.eq_ignore_ascii_case("exe"))
                    && path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.to_uppercase().starts_with("SDIO"))
            })
            .collect();
        // Prefer the lexicographically-newest x64 build, then any build.
        let is_x64 = |p: &&PathBuf| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.to_uppercase().contains("X64"))
        };
        entries
            .iter()
            .filter(is_x64)
            .max()
            .or_else(|| entries.iter().max())
            .cloned()
    }

    /// Opens SDIO's GUI, offering to install it via winget when it is absent.
    ///
    /// Deliberately opens the GUI rather than running `-autoinstall`. Swapping
    /// GPU/chipset/storage drivers is the most destructive thing this tool can
    /// do, so the user should see what will change before it changes; SDIO's
    /// own author points people at its scripting engine rather than the
    /// unattended switches, and the first run downloads driver packs measured
    /// in gigabytes over BitTorrent. `Setup-NewPC.ps1` keeps the unattended
    /// path, where a restore point has just been taken.
    ///
    /// No arguments, and `spawn_detached` sets the working directory to the
    /// exe's own folder -- required, because sdio.cfg refers to `drivers` and
    /// `indexes` by RELATIVE path.
    fn launch_sdio(&mut self) {
        // Re-run autodiscovery first so an SDIO installed a moment ago is
        // found without restarting the dashboard (the RAPR button already
        // does this; this one used to dead-end instead).
        if self.resolve_sdio_exe().is_none() {
            if let Some(root) = &self.root {
                self.settings = settings::load_settings(root);
            }
        }
        match self.resolve_sdio_exe() {
            Some(exe) => {
                if let Err(e) = spawn_detached(&exe, &[]) {
                    self.push_error(format!("Failed to launch SDIO: {e}"));
                }
            }
            None => {
                // Don't dead-end on "edit settings.json" -- offer the install.
                // winget is the right source: HTTPS *and* a pinned hash, which
                // a bare download URL does not give you.
                let mut cmd = Command::new("cmd");
                cmd.args([
                    "/c",
                    "winget install --id GlennDelahoy.SnappyDriverInstallerOrigin -e --accept-package-agreements --accept-source-agreements && pause",
                ]);
                #[cfg(windows)]
                cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
                match cmd.spawn() {
                    Ok(_) => self.push_log(
                        "[drivers] SDIO not found - installing via winget; try the button again once it finishes.".to_string(),
                    ),
                    Err(e) => self.push_error(format!("winget launch failed: {e}")),
                }
            }
        }
    }

    fn refresh_drivers(&mut self, ctx: &egui::Context) {
        self.drivers_loading = true;
        self.drivers_error = None;
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        let lang = self.lang;
        let timeout = Duration::from_secs(self.settings.driver_query_timeout_sec.max(1));
        std::thread::spawn(move || {
            let event = match drivers::run_pnputil(timeout) {
                Ok(text) => AppEvent::DriverList(drivers::parse_pnputil_output(&text)),
                Err(drivers::PnpUtilError::TimedOut) => {
                    AppEvent::Error(i18n::tr(lang).drivers_query_timeout.to_string())
                }
                Err(drivers::PnpUtilError::Failed(code)) => {
                    AppEvent::Error(i18n::pnputil_failed(lang, code))
                }
                Err(drivers::PnpUtilError::Io(e)) => {
                    AppEvent::Error(format!("Failed to run pnputil: {e}"))
                }
            };
            let _ = tx.send(event);
            ctx.request_repaint();
        });
    }

    fn refresh_installed(&mut self, ctx: &egui::Context) {
        if self.installed_loading {
            return;
        }
        self.installed_loading = true;
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let apps = system::query_installed(Duration::from_secs(90));
            let _ = tx.send(AppEvent::InstalledApps(apps));
            ctx.request_repaint();
        });
    }

    fn refresh_services(&mut self, ctx: &egui::Context) {
        if self.services_loading {
            return;
        }
        self.services_loading = true;
        self.services_fetched = true;
        self.services_error = None;
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = system::query_services(Duration::from_secs(60));
            let _ = tx.send(AppEvent::ServiceList(result));
            ctx.request_repaint();
        });
    }

    fn refresh_startup(&mut self, ctx: &egui::Context) {
        if self.autostart_loading {
            return;
        }
        self.autostart_loading = true;
        self.autostart_fetched = true;
        self.autostart_error = None;
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = system::query_startup(Duration::from_secs(60));
            let _ = tx.send(AppEvent::StartupList(result));
            ctx.request_repaint();
        });
    }

    fn refresh_tasks(&mut self, ctx: &egui::Context) {
        if self.tasks_loading {
            return;
        }
        self.tasks_loading = true;
        self.tasks_fetched = true;
        self.tasks_error = None;
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = system::query_tasks(Duration::from_secs(90));
            let _ = tx.send(AppEvent::TaskList(result));
            ctx.request_repaint();
        });
    }

    fn save_pins(&mut self) {
        let t = self.tr();
        if let Some(bat) = &self.bat_path {
            match pins::write_pins(bat, &self.pins) {
                Ok(()) => {
                    self.pin_save_msg = Some(t.pins_saved_msg.to_string());
                    self.pin_error = None;
                }
                Err(e) => {
                    self.pin_error = Some(format!("{} {e}", t.pins_save_failed_prefix));
                }
            }
        }
    }
}

/// One phase of the run for the progress estimate: the `[tag]` that starts
/// it and the cumulative 0-100 range it covers.
#[derive(Debug, Clone)]
struct Milestone {
    tag: &'static str,
    start: f32,
    end: f32,
}

/// Builds the milestone plan for the checked categories, normalized to 100.
/// Weights are rough relative durations observed in real runs; the raw
/// (untagged) topgrade output is folded into the winget phase's weight.
/// `[ea]` and the second `[launch]` are deliberately absent: `[ea]` also
/// fires during setup (detection), which would jump the bar forward.
fn build_milestones(wu: bool, store: bool, apps: bool, steam: bool) -> Vec<Milestone> {
    let mut plan: Vec<(&'static str, f32)> = vec![("setup", 3.0)];
    if store {
        plan.push(("store", 12.0));
    }
    if apps {
        plan.push(("launch", 1.0));
        plan.push(("jdownloader", 4.0));
        plan.push(("winget", 32.0)); // includes the raw topgrade output
    }
    if wu {
        plan.push(("winupdate", 24.0));
    }
    if steam {
        plan.push(("steam", 16.0));
    }

    let total: f32 = plan.iter().map(|(_, w)| w).sum();
    let mut out = Vec::with_capacity(plan.len());
    let mut acc = 0.0;
    for (tag, w) in plan {
        let start = acc / total * 100.0;
        acc += w;
        let end = acc / total * 100.0;
        out.push(Milestone { tag, start, end });
    }
    out
}

/// Parses winget's "(i/n) Found ..." progress counter from a raw line.
fn parse_counter(line: &str) -> Option<(u32, u32)> {
    let t = line.trim_start();
    let rest = t.strip_prefix('(')?;
    let close = rest.find(')')?;
    let inner = &rest[..close];
    let (a, b) = inner.split_once('/')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// One selectable app inside the bundle-chooser dialog.
#[derive(Debug, Clone)]
struct BundleApp {
    slug: String,
    name: String,
    category: String,
    description: String,
    /// Portuguese description (apps.json `description_pt`); empty = fall
    /// back to the English one.
    description_pt: String,
    winget: String,
    choco: String,
    selected: bool,
}

impl BundleApp {
    fn description_for(&self, lang: Lang) -> &str {
        if lang == Lang::PtBr && !self.description_pt.is_empty() {
            &self.description_pt
        } else {
            &self.description
        }
    }
}

/// Loads the full apps.json catalog, sorted by category then name. With a
/// `preset`, that pack's slug list decides which entries start pre-checked;
/// with `None`, everything starts unchecked.
fn load_bundle(root: &Path, preset: Option<&str>) -> Result<Vec<BundleApp>, String> {
    let catalog_text =
        std::fs::read_to_string(root.join("apps.json")).map_err(|e| format!("apps.json: {e}"))?;
    let catalog: serde_json::Value =
        serde_json::from_str(&catalog_text).map_err(|e| format!("apps.json: {e}"))?;

    let default_slugs: Vec<String> = match preset {
        Some(preset) => {
            let preset_path = root.join("presets").join(format!("{preset}.json"));
            let preset_text =
                std::fs::read_to_string(&preset_path).map_err(|e| format!("{preset}.json: {e}"))?;
            serde_json::from_str(&preset_text).map_err(|e| format!("{preset}.json: {e}"))?
        }
        None => Vec::new(),
    };
    let defaults: std::collections::HashSet<&str> = default_slugs
        .iter()
        .map(std::string::String::as_str)
        .collect();

    let obj = catalog
        .as_object()
        .ok_or_else(|| "apps.json: expected a JSON object".to_string())?;

    let mut out = Vec::with_capacity(obj.len());
    for (slug, entry) in obj {
        let field = |key: &str| -> String {
            entry
                .get(key)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        };
        let name = {
            let n = field("content");
            if n.is_empty() {
                slug.clone()
            } else {
                n
            }
        };
        out.push(BundleApp {
            name,
            category: field("category"),
            description: field("description"),
            description_pt: field("description_pt"),
            winget: field("winget"),
            choco: field("choco"),
            selected: defaults.contains(slug.as_str()),
            slug: slug.clone(),
        });
    }
    out.sort_by(|a, b| {
        a.category
            .cmp(&b.category)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(out)
}

fn discover_presets(dir: &Path) -> Vec<(String, usize)> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let path = e.path();
            if path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("json"))
            {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    // winutil-*.json are tweak configs, not app packs.
                    if stem.starts_with("winutil") {
                        continue;
                    }
                    let count = std::fs::read_to_string(&path)
                        .ok()
                        .and_then(|text| serde_json::from_str::<Vec<String>>(&text).ok())
                        .map_or(0, |slugs| slugs.len());
                    out.push((stem.to_string(), count));
                }
            }
        }
    }
    // Show the curated packs in a friendly order: basic, dev, full, then rest.
    let rank = |slug: &str| match slug {
        "new-pc-basic" => 0,
        "dev-machine" => 1,
        "full" => 2,
        _ => 3,
    };
    out.sort_by(|a, b| rank(&a.0).cmp(&rank(&b.0)).then_with(|| a.0.cmp(&b.0)));
    out
}

/// Clickable column header that drives a TableSort (click = sort by this
/// column, click again = reverse).
fn sort_header(ui: &mut egui::Ui, label: &str, field: SortField, sort: &mut TableSort) {
    let text = egui::RichText::new(format!("{label}{}", sort.arrow(field))).strong();
    if ui.add(egui::Button::new(text).frame(false)).clicked() {
        sort.click(field);
    }
}

/// Ranks an advice for sorting: safe-to-disable first, unknown last.
fn advice_sort_rank(entry: Option<&'static advice::AdviceEntry>) -> u8 {
    match entry.map(|e| e.advice) {
        Some(Advice::SafeOff) => 0,
        Some(Advice::Optional) => 1,
        Some(Advice::Keep) => 2,
        None => 3,
    }
}

/// Compares two optional measured times, keeping unmeasured rows together.
fn cmp_time(a: Option<f64>, b: Option<f64>) -> std::cmp::Ordering {
    match (a, b) {
        (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal),
        (Some(_), None) => std::cmp::Ordering::Greater,
        (None, Some(_)) => std::cmp::Ordering::Less,
        (None, None) => std::cmp::Ordering::Equal,
    }
}

/// Right-aligned "3.9 s" cell for a measured startup time (blank if none).
fn time_cell(ui: &mut egui::Ui, secs: Option<f64>) {
    if let Some(secs) = secs {
        let color = if secs >= 3.0 {
            theme::warn_amber()
        } else {
            theme::subtle_text()
        };
        ui.label(egui::RichText::new(format!("{secs:.1} s")).small().color(color));
    }
}

/// Colored advice badge ("keep" / "your choice" / "safe to turn off") with
/// the curated note as hover text. Draws a subtle dash for unknown items.
fn advice_badge(
    ui: &mut egui::Ui,
    t: &Strings,
    lang: Lang,
    entry: Option<&'static advice::AdviceEntry>,
) {
    match entry {
        Some(e) => {
            let (label, color) = match e.advice {
                Advice::Keep => (t.advice_keep, theme::status_ok()),
                Advice::Optional => (t.advice_optional, theme::warn_amber()),
                Advice::SafeOff => (t.advice_safeoff, theme::subtle_text()),
            };
            ui.label(egui::RichText::new(label).small().color(color))
                .on_hover_text(e.note(lang));
        }
        None => {
            ui.label(egui::RichText::new("\u{2014}").small().color(theme::status_idle()));
        }
    }
}

/// Opens a Windows shell target (an .msc console, an ms-settings: URI, ...)
/// detached and without flashing a console window.
fn open_windows_target(target: &str) {
    let mut cmd = Command::new("cmd");
    cmd.args(["/c", "start", "", target]);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    let _ = cmd.spawn();
}

fn spawn_detached(path: &Path, args: &[&str]) -> std::io::Result<()> {
    let mut cmd = Command::new(path);
    cmd.args(args);
    if let Some(dir) = path.parent() {
        cmd.current_dir(dir);
    }
    cmd.spawn().map(|_| ())
}

fn status_label(t: &Strings, status: Status) -> &'static str {
    match status {
        Status::Idle => t.status_chip_idle,
        Status::Running => t.status_chip_running,
        Status::Ok => t.status_chip_ok,
        Status::Error => t.status_chip_error,
        Status::Skipped => t.status_chip_skipped,
    }
}

fn status_color(status: Status) -> egui::Color32 {
    match status {
        Status::Idle => theme::status_idle(),
        Status::Running => theme::status_running(),
        Status::Ok => theme::status_ok(),
        Status::Error => theme::status_error(),
        Status::Skipped => theme::status_skipped(),
    }
}

fn status_chip(ui: &mut egui::Ui, t: &Strings, status: Status) {
    let color = status_color(status);
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(8.0, 8.0), egui::Sense::hover());
        ui.painter().circle_filled(rect.center(), 4.0, color);
        if status == Status::Running {
            ui.add(egui::Spinner::new().size(10.0));
        }
        ui.label(
            egui::RichText::new(status_label(t, status))
                .color(color)
                .small(),
        );
    });
}

impl eframe::App for DashboardApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Point the palette accessors at whichever theme egui is painting
        // with this frame -- it can change under us when the OS flips
        // light/dark while we're running.
        theme::sync(ctx);
        self.track_ui_scale(ctx);
        self.drain_events();

        if self.is_running {
            ctx.request_repaint_after(Duration::from_millis(250));
            // Creep the progress bar toward the current phase ceiling so it
            // keeps moving between milestones. Time-based (stable_dt is the
            // egui-documented animation delta) so extra repaints from mouse
            // movement don't accelerate the bar: exponential approach with a
            // ~15 s time constant, never overshooting.
            let dt = ctx.input(|i| i.stable_dt).min(0.1);
            let alpha = 1.0 - (-dt / 15.0).exp();
            self.progress = (self.progress_ceiling - self.progress)
                .max(0.0)
                .mul_add(alpha, self.progress);
        }

        self.draw_top_banner(ctx);
        self.draw_nav(ctx);
        self.draw_bottom_status(ctx);

        egui::CentralPanel::default().show(ctx, |ui| {
            match self.page {
                // Advanced and System host their own virtualized scroll
                // areas (log, tables) - nesting those inside another
                // ScrollArea breaks stick-to-bottom and row virtualization.
                Page::Advanced => self.draw_advanced_page(ui, ctx),
                Page::System => self.draw_system_page(ui, ctx),
                page => {
                    egui::ScrollArea::vertical()
                        .auto_shrink([false, false])
                        .show(ui, |ui| match page {
                            Page::Update => self.draw_update_page(ui, ctx),
                            Page::Install => self.draw_install_page(ui),
                            Page::NewPc => self.draw_newpc_page(ui),
                            Page::Optimize => self.draw_optimize_page(ui),
                            _ => self.draw_tools_page(ui),
                        });
                }
            }
        });

        self.draw_reboot_dialog(ctx);
        self.draw_nvclean_help(ctx);
    }

    /// Don't leave the update chain running with no UI attached to it.
    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        if !self.is_running {
            return;
        }
        self.request_stop();
        self.wait_for_engine_stop(Duration::from_secs(5));
    }
}

/// Lays out `add` inside a horizontally centered column, so pages read like a
/// document instead of hugging the left edge of a maximized window.
///
/// `preferred_w` is the target width on an ordinary window (and the floor
/// below which the column never shrinks further than available space). On a
/// much wider window -- a large monitor, or several thousand pixels on an
/// ultrawide/4K setup -- staying pinned at `preferred_w` wastes most of the
/// window and forces far more vertical scrolling than the content needs, so
/// the column grows past it, capped at `MAX_W` so prose doesn't turn into
/// unreadably long lines.
fn centered_column(ui: &mut egui::Ui, preferred_w: f32, add: impl FnOnce(&mut egui::Ui)) {
    const MAX_W: f32 = 1500.0;
    let available = ui.available_width();
    let target = (available * 0.65).clamp(preferred_w, MAX_W);
    let w = available.min(target);
    let pad = ((available - w) / 2.0).max(0.0);
    ui.horizontal(|ui| {
        ui.add_space(pad);
        ui.vertical(|ui| {
            ui.set_width(w);
            add(ui);
        });
    });
}

impl DashboardApp {
    fn draw_top_banner(&mut self, ctx: &egui::Context) {
        let t = self.tr();
        let mut selected_lang: Option<Lang> = None;
        let mut selected_theme: Option<ThemeChoice> = None;
        let mut selected_scale: Option<f32> = None;

        egui::TopBottomPanel::top("top_banner").show(ctx, |ui| {
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                ui.heading(egui::RichText::new(t.app_heading).strong());
                ui.add_space(8.0);
                ui.add(
                    egui::Label::new(
                        egui::RichText::new(t.tagline)
                            .small()
                            .color(theme::subtle_text()),
                    )
                    .truncate(),
                );
            });

            // Controls get their own row. A right_to_left group claims the
            // remaining width of whatever row it is in, so sharing a row with
            // the heading meant they simply drew on top of each other once
            // Text size went above 100% - first over the tagline, then over
            // the heading itself.
            ui.horizontal(|ui| {
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    egui::ComboBox::from_label(t.language_label)
                        .selected_text(match self.lang {
                            Lang::En => t.language_en,
                            Lang::PtBr => t.language_pt_br,
                        })
                        .show_ui(ui, |ui| {
                            if ui
                                .selectable_label(self.lang == Lang::En, t.language_en)
                                .clicked()
                            {
                                selected_lang = Some(Lang::En);
                            }
                            if ui
                                .selectable_label(self.lang == Lang::PtBr, t.language_pt_br)
                                .clicked()
                            {
                                selected_lang = Some(Lang::PtBr);
                            }
                        });

                    ui.add_space(12.0);
                    // Text size. egui's own Ctrl+Plus / Ctrl+Minus still work;
                    // this makes the choice discoverable and persistent.
                    let pct = |s: f32| format!("{}%", (s * 100.0).round() as i32);
                    egui::ComboBox::from_label(t.text_size_label)
                        .selected_text(pct(self.ui_scale))
                        .show_ui(ui, |ui| {
                            for scale in theme::UI_SCALES {
                                let selected = (self.ui_scale - scale).abs() < f32::EPSILON;
                                if ui.selectable_label(selected, pct(scale)).clicked() {
                                    selected_scale = Some(scale);
                                }
                            }
                        });

                    ui.add_space(12.0);
                    let theme_name = |c: ThemeChoice| match c {
                        ThemeChoice::System => t.theme_system,
                        ThemeChoice::Light => t.theme_light,
                        ThemeChoice::Dark => t.theme_dark,
                    };
                    egui::ComboBox::from_label(t.theme_label)
                        .selected_text(theme_name(self.theme_choice))
                        .show_ui(ui, |ui| {
                            for choice in
                                [ThemeChoice::System, ThemeChoice::Light, ThemeChoice::Dark]
                            {
                                if ui
                                    .selectable_label(
                                        self.theme_choice == choice,
                                        theme_name(choice),
                                    )
                                    .clicked()
                                {
                                    selected_theme = Some(choice);
                                }
                            }
                        });
                });
            });
            ui.add_space(4.0);

            if let Some(err) = &self.startup_error {
                egui::Frame::new()
                    .fill(theme::banner_warn_bg())
                    .inner_margin(egui::Margin::same(8))
                    .show(ui, |ui| {
                        ui.colored_label(theme::warn_amber(), format!("⚠ {err}"));
                    });
                ui.add_space(4.0);
            }

            if self.reboot.requires_reboot() {
                egui::Frame::new()
                    .fill(theme::banner_caution_bg())
                    .inner_margin(egui::Margin::same(8))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.colored_label(theme::warn_amber(), t.reboot_detected_prefix);
                            if self.reboot.cbs {
                                ui.colored_label(theme::warn_amber(), t.reboot_cbs);
                            }
                            if self.reboot.windows_update {
                                ui.colored_label(theme::warn_amber(), t.reboot_windows_update);
                            }
                            if self.reboot.pending_file_rename {
                                ui.colored_label(theme::warn_amber(), t.reboot_pending_file_rename);
                            }
                        });
                    });
                ui.add_space(4.0);
            }
            ui.add_space(2.0);
        });

        if let Some(lang) = selected_lang {
            self.set_language(lang);
        }
        if let Some(choice) = selected_theme {
            self.set_theme(ctx, choice);
        }
        if let Some(scale) = selected_scale {
            self.set_ui_scale(ctx, scale);
        }
    }

    /// Big page selector under the banner: the three things a user comes
    /// here to do, plus Advanced for the power-user surfaces.
    fn draw_nav(&mut self, ctx: &egui::Context) {
        let t = self.tr();
        egui::TopBottomPanel::top("nav_bar").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.add_space(4.0);
                for (page, label) in [
                    (Page::Update, t.nav_update),
                    (Page::Install, t.nav_install),
                    (Page::NewPc, t.nav_newpc),
                    (Page::Optimize, t.nav_optimize),
                    (Page::System, t.nav_system),
                    (Page::Tools, t.nav_tools),
                    (Page::Advanced, t.nav_advanced),
                ] {
                    if tab_button(ui, self.page == page, label, 16.0).clicked() {
                        self.page = page;
                    }
                }
            });
            ui.add_space(6.0);
        });
    }

    fn draw_update_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        centered_column(ui, 720.0, |ui| {
            ui.add_space(14.0);
            ui.label(egui::RichText::new(t.update_title).size(26.0).strong());
            ui.label(egui::RichText::new(t.update_subtitle).color(theme::subtle_text()));
            ui.add_space(10.0);

            let wu_status = self.status(Category::WindowsUpdate);
            let store_status = self.status(Category::Store);
            let apps_status = self.status(Category::Apps);
            let steam_status = self.status(Category::Steam);

            category_row(
                ui,
                t,
                &mut self.cat_windows_update,
                wu_status,
                t.cat_windows_update,
                t.cat_windows_update_desc,
                true,
            );
            category_row(
                ui,
                t,
                &mut self.cat_store,
                store_status,
                t.cat_store,
                t.cat_store_desc,
                true,
            );
            category_row(
                ui,
                t,
                &mut self.cat_apps,
                apps_status,
                t.cat_apps,
                t.cat_apps_desc,
                true,
            );
            category_row(
                ui,
                t,
                &mut self.cat_steam,
                steam_status,
                t.cat_steam,
                t.cat_steam_desc,
                true,
            );

            ui.add_space(10.0);
            // Drivers aren't part of the batch run above (SDIO opens its own
            // GUI so you can review what it proposes before anything
            // installs -- it can't run silently as one more checkbox), so
            // it's a separate button rather than a fifth category card. Same
            // action as the Tools and Driver Store pages.
            if ui.button(t.drivers_update_btn).clicked() {
                self.launch_sdio();
            }
            ui.label(egui::RichText::new(t.drivers_update_hint).weak().small());

            ui.add_space(10.0);

            let any_checked =
                self.cat_windows_update || self.cat_store || self.cat_apps || self.cat_steam;
            let run_enabled = any_checked && !self.is_running && self.root.is_some();
            let run_button = egui::Button::new(
                egui::RichText::new(if self.is_running {
                    t.running_button
                } else {
                    t.run_cta
                })
                .strong()
                .size(18.0)
                .color(theme::on_accent()),
            )
            .fill(if run_enabled {
                theme::accent_green()
            } else {
                theme::accent_green_dim()
            })
            .min_size(egui::vec2(ui.available_width(), 48.0));
            if ui.add_enabled(run_enabled, run_button).clicked() {
                self.start_run(ctx, false);
            }

            // Stop: only while a run is in flight. Once pressed the flag is
            // latched, so it disables itself until EngineExited arrives -
            // pressing it again would do nothing anyway.
            if self.is_running {
                ui.add_space(6.0);
                let stopping = self
                    .engine_stop
                    .as_ref()
                    .is_some_and(|s| s.load(Ordering::Relaxed));
                let stop_button = egui::Button::new(
                    egui::RichText::new(if stopping { t.stopping_button } else { t.stop_cta })
                        .strong()
                        .size(16.0)
                        .color(theme::on_accent()),
                )
                .fill(theme::status_error())
                .min_size(egui::vec2(ui.available_width(), 36.0));
                if ui.add_enabled(!stopping, stop_button).clicked() {
                    self.request_stop();
                    self.push_log("[run] Stop requested - ending the run...".to_string());
                }
            }

            // Progress (kept visible after completion)
            if self.is_running || self.engine_exit.is_some() {
                ui.add_space(6.0);
                ui.add(
                    egui::ProgressBar::new(self.progress / 100.0)
                        .show_percentage()
                        .animate(self.is_running),
                );
                if self.is_running {
                    ui.horizontal(|ui| {
                        if let Some(m) = self.milestones.get(self.milestone_idx) {
                            ui.label(
                                egui::RichText::new(format!(
                                    "{} {}",
                                    t.progress_phase_prefix, m.tag
                                ))
                                .small()
                                .color(theme::subtle_text()),
                            );
                        }
                        if let Some(start) = self.run_start {
                            ui.with_layout(
                                egui::Layout::right_to_left(egui::Align::Center),
                                |ui| {
                                    ui.label(
                                        egui::RichText::new(format!(
                                            "{} {}",
                                            t.elapsed_prefix,
                                            format_duration(start.elapsed())
                                        ))
                                        .small()
                                        .color(theme::subtle_text()),
                                    );
                                },
                            );
                        }
                    });
                    if let Some(last) = self.last_output {
                        let stale = self.settings.stale_output_warn_sec;
                        if last.elapsed().as_secs() >= stale {
                            ui.colored_label(theme::warn_amber(), t.waiting_for_output);
                        }
                    }
                }
            }

            // Live log tail while running
            if self.is_running {
                ui.add_space(8.0);
                theme::card().show(ui, |ui| {
                    let skip = self.log_lines.len().saturating_sub(10);
                    for line in self.log_lines.iter().skip(skip) {
                        let (tag, is_warn) = extract_tag(line);
                        let color = if is_warn {
                            theme::warn_amber()
                        } else {
                            tag.map_or(theme::log_default(), theme::tag_color)
                        };
                        ui.label(
                            egui::RichText::new(line.as_str())
                                .monospace()
                                .small()
                                .color(color),
                        );
                    }
                });
                if ui.link(t.view_full_log).clicked() {
                    self.page = Page::Advanced;
                    self.active_tab = Tab::Log;
                }
            }

            // Result banner after a run
            if !self.is_running && self.engine_exit.is_some() {
                ui.add_space(8.0);
                let had_summary = self.summary.is_some();
                let any_error = self.status.values().any(|s| *s == Status::Error);
                let (title, bg, fg) = if !had_summary {
                    (
                        t.result_no_summary_title,
                        theme::banner_warn_bg(),
                        theme::warn_amber(),
                    )
                } else if any_error {
                    (
                        t.result_issues_title,
                        theme::banner_caution_bg(),
                        theme::warn_amber(),
                    )
                } else {
                    (
                        t.result_ok_title,
                        theme::banner_ok_bg(),
                        theme::status_ok(),
                    )
                };
                egui::Frame::new()
                    .fill(bg)
                    .corner_radius(egui::CornerRadius::same(10))
                    .inner_margin(egui::Margin::same(14))
                    .show(ui, |ui| {
                        ui.label(egui::RichText::new(title).size(17.0).strong().color(fg));
                        ui.add_space(4.0);
                        let cats: [(bool, &str, Category); 4] = [
                            (
                                self.cat_windows_update,
                                t.cat_windows_update,
                                Category::WindowsUpdate,
                            ),
                            (self.cat_store, t.toast_cat_store, Category::Store),
                            (self.cat_apps, t.toast_cat_apps, Category::Apps),
                            (
                                self.cat_steam,
                                t.toast_cat_steam,
                                Category::Steam,
                            ),
                        ];
                        for (checked, label, cat) in cats {
                            if !checked {
                                continue;
                            }
                            let status = self.status(cat);
                            ui.horizontal(|ui| {
                                ui.label(label);
                                ui.label(
                                    egui::RichText::new(status_label(t, status))
                                        .color(status_color(status)),
                                );
                            });
                        }
                        ui.add_space(4.0);
                        ui.horizontal(|ui| {
                            if ui.link(t.view_full_log).clicked() {
                                self.page = Page::Advanced;
                                self.active_tab = Tab::Log;
                            }
                            if ui.link(t.tab_summary).clicked() {
                                self.page = Page::Advanced;
                                self.active_tab = Tab::Summary;
                            }
                        });
                    });
            }
            ui.add_space(16.0);
        });
    }

    fn status(&self, cat: Category) -> Status {
        self.status.get(&cat).copied().unwrap_or(Status::Idle)
    }

    fn draw_bottom_status(&self, ctx: &egui::Context) {
        let t = self.tr();
        egui::TopBottomPanel::bottom("bottom_status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                let run_state = if self.is_running {
                    t.status_running.to_string()
                } else if let Some(exit) = self.engine_exit {
                    let had_summary = self.summary.is_some();
                    let any_error = self.status.values().any(|s| *s == Status::Error);
                    let completed = |any_error: bool| {
                        if any_error {
                            t.status_completed_with_issues.to_string()
                        } else {
                            t.status_completed.to_string()
                        }
                    };
                    match exit {
                        EngineExit::Code(0) => completed(any_error),
                        // A watchdog stop after a real summary was parsed is
                        // the expected end of every run (the bat trails with
                        // `timeout /t 60`), not a failure.
                        EngineExit::Stopped if had_summary => completed(any_error),
                        // Stopped with no summary ever received: the engine
                        // died or hung early in the run. This *is* the
                        // scary case worth calling out distinctly.
                        EngineExit::Stopped => t.status_engine_no_summary.to_string(),
                        EngineExit::Code(code) => i18n::status_failed(self.lang, code),
                    }
                } else {
                    t.status_idle.to_string()
                };
                ui.label(run_state);

                ui.separator();
                let engine_indicator = self.bat_path.as_ref().map_or_else(
                    || t.engine_not_found.to_string(),
                    |p| p.display().to_string(),
                );
                ui.label(egui::RichText::new(engine_indicator).small().weak());

                if let Some(err) = &self.last_error {
                    ui.separator();
                    ui.colored_label(
                        theme::status_error(),
                        format!("{} {err}", t.last_error_prefix),
                    );
                }

                if self.is_running {
                    if let Some(start) = self.run_start {
                        let elapsed = start.elapsed();
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            ui.label(format_duration(elapsed));
                        });
                    }
                }
            });
        });
    }

    fn draw_advanced_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        ui.horizontal(|ui| {
            ui.selectable_value(&mut self.active_tab, Tab::Log, t.tab_log);
            ui.selectable_value(&mut self.active_tab, Tab::Summary, t.tab_summary);
            ui.selectable_value(&mut self.active_tab, Tab::Pins, t.tab_pins);
            ui.selectable_value(&mut self.active_tab, Tab::DriverStore, t.tab_driver_store);
        });
        ui.separator();

        match self.active_tab {
            Tab::Log => self.draw_log_tab(ui),
            Tab::Summary => self.draw_summary_tab(ui),
            Tab::Pins => self.draw_pins_tab(ui, ctx),
            Tab::DriverStore => self.draw_driver_store_tab(ui, ctx),
        }
    }

    /// Startup & Services page: what runs automatically, with per-item
    /// on/off switches (Task Manager's own StartupApproved mechanism) and
    /// per-service start-type control, explained via Windows' descriptions.
    fn draw_system_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        ui.add_space(6.0);
        ui.label(egui::RichText::new(t.system_title).size(22.0).strong());
        ui.label(egui::RichText::new(t.system_subtitle).color(theme::subtle_text()));
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            for (section, label) in [
                (SystemSection::Startup, t.tab_startup),
                (SystemSection::Tasks, t.tab_tasks),
                (SystemSection::Services, t.tab_services),
            ] {
                if tab_button(ui, self.system_section == section, label, 15.0).clicked() {
                    self.system_section = section;
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui
                    .button(t.system_export_button)
                    .on_hover_text(t.system_export_hover)
                    .clicked()
                {
                    self.spawn_export_report();
                }
                ui.checkbox(&mut self.system_show_advanced, t.system_advanced_label)
                    .on_hover_text(t.system_advanced_hover);
            });
        });
        ui.separator();
        match self.system_section {
            SystemSection::Startup => self.draw_startup_section(ui, ctx),
            SystemSection::Tasks => self.draw_tasks_section(ui, ctx),
            SystemSection::Services => self.draw_services_section(ui, ctx),
        }
    }

    /// Scheduled tasks with boot/logon triggers — the ones that slow down
    /// sign-in — with the same toggle + advice treatment as startup items.
    fn draw_tasks_section(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        if !self.tasks_fetched {
            self.refresh_tasks(ctx);
        }
        ui.label(egui::RichText::new(t.tasks_intro).weak());
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.tasks_loading, egui::Button::new(t.drivers_refresh))
                .clicked()
            {
                self.refresh_tasks(ctx);
            }
            if ui.button(t.tasks_open_scheduler).clicked() {
                open_windows_target("taskschd.msc");
            }
            if self.tasks_loading {
                ui.add(egui::Spinner::new());
                ui.label(t.tasks_loading);
            }
            if let Some(err) = &self.tasks_error {
                ui.colored_label(theme::status_error(), err);
            }
            ui.label(t.filter_label);
            ui.text_edit_singleline(&mut self.tasks_filter);
        });
        ui.add_space(6.0);

        let lang = self.lang;
        let show_advanced = self.system_show_advanced;
        let is_protected = |s: &TaskEntry| {
            matches!(
                task_advice(s).map(|e| e.advice),
                Some(Advice::Keep)
            )
        };
        let hidden_count = if show_advanced {
            0
        } else {
            self.tasks.iter().filter(|s| is_protected(s)).count()
        };
        if hidden_count > 0 {
            ui.label(
                egui::RichText::new(i18n::hidden_items(lang, hidden_count))
                    .small()
                    .color(theme::subtle_text()),
            );
        }
        let filter = self.tasks_filter.to_lowercase();
        let mut rows: Vec<(TaskEntry, Option<f64>)> = self
            .tasks
            .iter()
            .filter(|s| show_advanced || !is_protected(s))
            .filter(|s| {
                filter.is_empty()
                    || s.name.to_lowercase().contains(&filter)
                    || s.path.to_lowercase().contains(&filter)
            })
            .map(|s| {
                let secs = system::boot_time_for(&self.boot_times, &s.name);
                (s.clone(), secs)
            })
            .collect();
        let mut sort = self.tasks_sort;
        rows.sort_by(|(a, ta), (b, tb)| {
            let ord = match sort.field {
                // asc = enabled first ("On" on top).
                SortField::Status => b.enabled().cmp(&a.enabled()),
                // Must use the same lookup as the badge, or sorting by the
                // Advice column doesn't group by what the column shows.
                SortField::Advice => {
                    advice_sort_rank(task_advice(a)).cmp(&advice_sort_rank(task_advice(b)))
                }
                SortField::Time => cmp_time(*ta, *tb),
                _ => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            if sort.asc {
                ord
            } else {
                ord.reverse()
            }
        });
        let busy = self.tasks_busy.clone();
        let mut toggle: Option<TaskEntry> = None;

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                egui_extras::TableBuilder::new(ui)
                    .striped(true)
                    .column(egui_extras::Column::initial(108.0).at_least(72.0))
                    .column(egui_extras::Column::initial(148.0).at_least(96.0))
                    .column(egui_extras::Column::initial(70.0).at_least(52.0))
                    .column(egui_extras::Column::initial(280.0).at_least(160.0))
                    .column(egui_extras::Column::remainder().at_least(180.0))
                    .header(20.0, |mut header| {
                        header.col(|ui| {
                            sort_header(ui, t.startup_col_enabled, SortField::Status, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.advice_col, SortField::Advice, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.time_col, SortField::Time, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.startup_col_name, SortField::Name, &mut sort);
                        });
                        header.col(|ui| {
                            ui.strong(t.what_col);
                        });
                    })
                    .body(|body| {
                        body.rows(24.0, rows.len(), |mut row| {
                            let (s, secs) = &rows[row.index()];
                            row.col(|ui| {
                                let this_busy = busy.as_deref() == Some(s.name.as_str());
                                let (label, color) = if this_busy {
                                    ("...", theme::subtle_text())
                                } else if s.enabled() {
                                    (t.startup_on, theme::accent_green())
                                } else {
                                    (t.startup_off, theme::subtle_text())
                                };
                                let button = egui::Button::new(
                                    egui::RichText::new(label).strong().color(color),
                                )
                                .min_size(egui::vec2(72.0, 20.0));
                                if ui.add_enabled(busy.is_none(), button).clicked() {
                                    toggle = Some(s.clone());
                                }
                            });
                            row.col(|ui| {
                                advice_badge(
                                    ui,
                                    t,
                                    lang,
                                    task_advice(s),
                                );
                            });
                            row.col(|ui| {
                                time_cell(ui, *secs);
                            });
                            row.col(|ui| {
                                let text = if s.enabled() {
                                    egui::RichText::new(&s.name)
                                } else {
                                    egui::RichText::new(&s.name)
                                        .strikethrough()
                                        .color(theme::subtle_text())
                                };
                                ui.add(egui::Label::new(text).truncate())
                                    .on_hover_text(format!("{}{}", s.path, s.name));
                            });
                            row.col(|ui| {
                                // Curated note > the task's own description >
                                // what it launches. Folder + command on hover.
                                let what = match task_advice(s) {
                                    Some(e) => e.note(lang).to_string(),
                                    None if !s.description.is_empty() => s.description.clone(),
                                    None => i18n::runs_at_signin(
                                        lang,
                                        &system::exe_name(&s.command),
                                    ),
                                };
                                ui.add(
                                    egui::Label::new(
                                        egui::RichText::new(&what)
                                            .small()
                                            .color(theme::subtle_text()),
                                    )
                                    .truncate(),
                                )
                                .on_hover_text(format!("{what}\n\n{}{}\n{}", s.path, s.name, s.command));
                            });
                        });
                    });
            });
        self.tasks_sort = sort;

        if let Some(entry) = toggle {
            self.spawn_toggle_task(ctx, entry);
        }
    }

    /// Applies a scheduled-task enable/disable in the background, then
    /// re-queries the list.
    fn spawn_toggle_task(&mut self, ctx: &egui::Context, entry: TaskEntry) {
        self.tasks_busy = Some(entry.name.clone());
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            if let Err(e) = system::set_task_enabled(&entry.path, &entry.name, !entry.enabled()) {
                let _ = tx.send(AppEvent::Error(format!(
                    "Task toggle '{}' failed: {e}",
                    entry.name
                )));
            }
            let list = system::query_tasks(Duration::from_secs(90));
            let _ = tx.send(AppEvent::TaskList(list));
            ctx.request_repaint();
        });
    }

    fn draw_log_tab(&self, ui: &mut egui::Ui) {
        let row_height = ui.text_style_height(&egui::TextStyle::Monospace);
        let n = self.log_lines.len();
        egui::ScrollArea::vertical()
            .stick_to_bottom(true)
            .auto_shrink([false, false])
            .show_rows(ui, row_height, n, |ui, range| {
                for i in range {
                    if let Some(line) = self.log_lines.get(i) {
                        let (tag, is_warn) = extract_tag(line);
                        let color = if is_warn {
                            theme::warn_amber()
                        } else if line.starts_with("[stderr]") {
                            theme::status_error()
                        } else {
                            tag.map_or(theme::log_default(), theme::tag_color)
                        };
                        ui.label(egui::RichText::new(line).monospace().color(color));
                    }
                }
            });
    }

    fn draw_summary_tab(&self, ui: &mut egui::Ui) {
        let t = self.tr();
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                match &self.summary {
                    None => {
                        ui.label(egui::RichText::new(t.summary_empty).weak().italics());
                    }
                    Some(summary) => {
                        let rows: Vec<(&str, &Option<String>)> = vec![
                            ("winget", &summary.winget),
                            ("topgrade", &summary.topgrade),
                            (t.cat_windows_update, &summary.windows_update),
                            (t.summary_row_store, &summary.store),
                            (t.summary_row_steam, &summary.steam),
                            ("JDownloader", &summary.jdownloader),
                            ("EA app", &summary.ea_app),
                        ];
                        egui::Grid::new("summary_grid")
                            .num_columns(2)
                            .spacing([16.0, 6.0])
                            .show(ui, |ui| {
                                for (label, value) in rows {
                                    if let Some(v) = value {
                                        ui.label(label);
                                        // Same rule as the status chips - see
                                        // `summary_value_is_ok`.
                                        let color = if summary_value_is_ok(v) {
                                            theme::status_ok()
                                        } else if summary_value_is_skipped(v) {
                                            theme::status_skipped()
                                        } else {
                                            theme::status_error()
                                        };
                                        ui.colored_label(color, v);
                                        ui.end_row();
                                    }
                                }
                                if let Some(d) = &summary.duration {
                                    ui.label(t.summary_row_duration);
                                    ui.label(d);
                                    ui.end_row();
                                }
                                if let Some(log) = &summary.log_path {
                                    ui.label(t.summary_row_log_file);
                                    ui.label(log);
                                    ui.end_row();
                                }
                            });
                    }
                }

                ui.add_space(12.0);
                if let Some(exit) = self.engine_exit {
                    let had_summary = self.summary.is_some();
                    let (color, text) = match exit {
                        EngineExit::Code(0) => (theme::status_ok(), "0".to_string()),
                        EngineExit::Code(code) => (theme::status_error(), code.to_string()),
                        EngineExit::Stopped if had_summary => {
                            (theme::status_ok(), t.summary_exit_stopped.to_string())
                        }
                        EngineExit::Stopped => {
                            (theme::status_error(), t.summary_exit_stopped.to_string())
                        }
                    };
                    ui.colored_label(color, format!("{} {text}", t.summary_exit_code_prefix));
                }
            });
    }

    fn draw_tools_page(&mut self, ui: &mut egui::Ui) {
        let t = self.tr();
        centered_column(ui, 720.0, |ui| {
            ui.add_space(14.0);
            ui.label(egui::RichText::new(t.tools_title).size(26.0).strong());
            ui.label(egui::RichText::new(t.tools_subtitle).color(theme::subtle_text()));
            ui.add_space(10.0);

            #[derive(Clone, Copy, PartialEq)]
            enum Action {
                Sdio,
                Rapr,
                NvRecommended,
                NvAuto,
                NvOpen,
                Winutil,
            }
            let mut action: Option<Action> = None;

            theme::card().show(ui, |ui| {
                ui.strong(t.tools_group_drivers);
                ui.add_space(4.0);
                for (label, desc, act) in [
                    (t.tools_open_sdio, t.tools_sdio_desc, Action::Sdio),
                    (t.tools_open_rapr, t.tools_rapr_desc, Action::Rapr),
                    (
                        t.tools_nvidia_auto,
                        t.tools_nvidia_auto_desc,
                        Action::NvAuto,
                    ),
                    (
                        t.tools_nvclean_recommended,
                        t.tools_nvclean_reco_desc,
                        Action::NvRecommended,
                    ),
                    (
                        t.tools_open_nvclean,
                        t.tools_nvclean_open_desc,
                        Action::NvOpen,
                    ),
                ] {
                    ui.horizontal(|ui| {
                        if ui
                            .add_sized([340.0, 32.0], egui::Button::new(label))
                            .clicked()
                        {
                            action = Some(act);
                        }
                        ui.label(egui::RichText::new(desc).small().color(theme::subtle_text()));
                    });
                }
            });

            ui.add_space(8.0);
            theme::card().show(ui, |ui| {
                ui.strong(t.tools_group_system);
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    if ui
                        .add_sized([340.0, 32.0], egui::Button::new(t.tools_open_winutil))
                        .clicked()
                    {
                        action = Some(Action::Winutil);
                    }
                    ui.label(
                        egui::RichText::new(t.tools_winutil_desc)
                            .small()
                            .color(theme::subtle_text()),
                    );
                });
            });
            ui.add_space(16.0);

            match action {
                Some(Action::Sdio) => self.launch_sdio(),
                Some(Action::Rapr) => {
                    // Re-run autodiscovery so a just-installed RAPR is found
                    // without restarting the dashboard.
                    if let Some(root) = &self.root {
                        self.settings = settings::load_settings(root);
                    }
                    let path = self.settings.rapr_path.clone();
                    if path.is_empty() || !Path::new(&path).is_file() {
                        // Not installed: fetch it via winget in a visible
                        // console; autodiscovery picks it up on next launch.
                        let mut cmd = Command::new("cmd");
                        cmd.args([
                            "/c",
                            "winget install --id lostindark.DriverStoreExplorer -e --accept-package-agreements --accept-source-agreements && pause",
                        ]);
                        #[cfg(windows)]
                        cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
                        match cmd.spawn() {
                            Ok(_) => self.push_log(
                                "[tools] Driver Store Explorer not found - installing via winget; try the button again once it finishes.".to_string(),
                            ),
                            Err(e) => self.push_error(format!("winget launch failed: {e}")),
                        }
                    } else if let Err(e) = spawn_detached(Path::new(&path), &[]) {
                        self.push_error(format!("Failed to launch DriverStoreExplorer: {e}"));
                    }
                }
                Some(Action::NvRecommended) => {
                    let pkg = self.settings.nvclean_package_path.clone();
                    if !pkg.is_empty() && Path::new(&pkg).is_file() {
                        match spawn_detached(Path::new(&pkg), &["-y", "-noreboot"]) {
                            Ok(()) => {
                                self.push_log(
                                    "[drivers] Running prebuilt NVCleanstall package..."
                                        .to_string(),
                                );
                            }
                            Err(e) => {
                                self.push_error(format!("Failed to run NVCleanstall package: {e}"));
                            }
                        }
                    } else {
                        self.nvclean_help_open = true;
                    }
                }
                Some(Action::NvAuto) => {
                    // Fully automatic clean driver: query NVIDIA, download,
                    // extract core-only, silent install. Visible console.
                    if let Some(root) = &self.root {
                        let script = root.join("Get-NvidiaDriver.ps1");
                        let mut cmd = Command::new("powershell.exe");
                        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
                        cmd.arg(&script);
                        cmd.args(["-Install", "-KeepAudio"]);
                        #[cfg(windows)]
                        cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
                        match cmd.spawn() {
                            Ok(_) => self.push_log(
                                "[drivers] Clean NVIDIA driver update started in its own window."
                                    .to_string(),
                            ),
                            Err(e) => self.push_error(format!("Failed to start driver update: {e}")),
                        }
                    }
                }
                Some(Action::NvOpen) => {
                    // Re-discover, then auto-download the portable if absent.
                    if let Some(root) = &self.root {
                        self.settings = settings::load_settings(root);
                    }
                    let path = self.settings.nvclean_path.clone();
                    if path.is_empty() || !Path::new(&path).is_file() {
                        if let Some(root) = &self.root {
                            let script = root.join("Get-NVCleanstall.ps1");
                            let mut cmd = Command::new("powershell.exe");
                            cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
                            cmd.arg(&script);
                            cmd.arg("-Open");
                            #[cfg(windows)]
                            cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
                            match cmd.spawn() {
                                Ok(_) => self.push_log(
                                    "[drivers] Downloading portable NVCleanstall - it opens when ready."
                                        .to_string(),
                                ),
                                Err(e) => {
                                    self.push_error(format!("Failed to start download: {e}"))
                                }
                            }
                        }
                    } else if let Err(e) = spawn_detached(Path::new(&path), &[]) {
                        self.push_error(format!("Failed to launch NVCleanstall: {e}"));
                    }
                }
                Some(Action::Winutil) => {
                    let mut cmd = Command::new("powershell.exe");
                    cmd.args([
                        "-NoProfile",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-Command",
                        &self.settings.winutil_command,
                    ]);
                    #[cfg(windows)]
                    cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
                    if let Err(e) = cmd.spawn() {
                        self.push_error(format!("Failed to open winutil: {e}"));
                    }
                }
                None => {}
            }
        });
    }

    fn draw_install_page(&mut self, ui: &mut egui::Ui) {
        let t = self.tr();
        let lang = self.lang;
        centered_column(ui, 860.0, |ui| {
            ui.add_space(14.0);
            ui.label(egui::RichText::new(t.install_title).size(26.0).strong());
            ui.label(egui::RichText::new(t.install_subtitle).color(theme::subtle_text()));
            ui.add_space(10.0);

            if self.presets.is_empty() {
                ui.label(egui::RichText::new(t.tools_no_presets).weak());
            }

            // Step 1 (optional): pack cards, which just pre-check a set.
            let mut clicked_pack: Option<String> = None;
            ui.horizontal_wrapped(|ui| {
                for (slug, count) in &self.presets {
                    let (name, desc) = i18n::preset_display(lang, slug);
                    let display_name = if name.is_empty() { slug.as_str() } else { name };
                    let selected = self.bundle_preset.as_deref() == Some(slug.as_str());
                    let frame = if selected {
                        theme::card_selected()
                    } else {
                        theme::card()
                    };
                    let resp = frame
                        .show(ui, |ui| {
                            ui.set_width(240.0);
                            ui.set_min_height(96.0);
                            ui.vertical(|ui| {
                                ui.label(egui::RichText::new(display_name).size(17.0).strong());
                                ui.label(
                                    egui::RichText::new(desc).small().color(theme::subtle_text()),
                                );
                                ui.label(
                                    egui::RichText::new(format!("{count} {}", t.pack_apps_suffix))
                                        .small()
                                        .color(theme::accent_green()),
                                );
                            });
                        })
                        .response
                        .interact(egui::Sense::click());
                    if resp.hovered() {
                        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                    }
                    if resp.clicked() {
                        clicked_pack = Some(slug.clone());
                    }
                }
            });

            if let Some(slug) = clicked_pack {
                if let Some(root) = self.root.clone() {
                    match load_bundle(&root, Some(&slug)) {
                        Ok(apps) => {
                            self.bundle_apps = apps;
                            self.bundle_preset = Some(slug);
                        }
                        Err(e) => {
                            let prefix = t.bundle_load_failed_prefix;
                            self.push_error(format!("{prefix} {e}"));
                        }
                    }
                }
            }

            // Step 2: per-app selection
            if !self.bundle_apps.is_empty() {
                ui.add_space(10.0);
                ui.label(egui::RichText::new(t.install_step2_hint).color(theme::subtle_text()));
                let selected_count = self.bundle_apps.iter().filter(|a| a.selected).count();
                ui.horizontal(|ui| {
                    if ui.small_button(t.bundle_select_all).clicked() {
                        for a in &mut self.bundle_apps {
                            a.selected = true;
                        }
                    }
                    if ui.small_button(t.bundle_select_none).clicked() {
                        for a in &mut self.bundle_apps {
                            a.selected = false;
                        }
                    }
                });

                theme::card().show(ui, |ui| {
                    // Columns per category: name + visible description, with
                    // full details (ids, category) on hover. At least 2; more
                    // on a wide window so a long catalog doesn't turn into
                    // one tall, mostly-empty-on-the-sides scroll.
                    const MIN_COL_W: f32 = 300.0;
                    let cols = ((ui.available_width() - 36.0) / MIN_COL_W)
                        .floor()
                        .clamp(2.0, 4.0) as usize;
                    let col_w = ((ui.available_width() - 36.0) / cols as f32).max(220.0);
                    let apps = &mut self.bundle_apps;
                    let mut i = 0;
                    while i < apps.len() {
                        let cat = apps[i].category.clone();
                        let end = apps[i..]
                            .iter()
                            .position(|a| a.category != cat)
                            .map_or(apps.len(), |p| i + p);
                        ui.add_space(6.0);
                        ui.label(
                            egui::RichText::new(i18n::category_display(lang, &cat))
                                .strong()
                                .color(theme::accent_green()),
                        );
                        egui::Grid::new(format!("apps_grid_{cat}"))
                            .num_columns(cols)
                            .min_col_width(col_w)
                            .max_col_width(col_w)
                            .spacing([12.0, 4.0])
                            .show(ui, |ui| {
                                for (j, app) in apps[i..end].iter_mut().enumerate() {
                                    ui.vertical(|ui| {
                                        ui.set_width(col_w);
                                        // The whole name flips to bold green
                                        // when checked, so the state change is
                                        // obvious beyond the small checkmark.
                                        let name = if app.selected {
                                            egui::RichText::new(&app.name)
                                                .strong()
                                                .color(theme::accent_green())
                                        } else {
                                            egui::RichText::new(&app.name)
                                        };
                                        let desc = app.description_for(lang).to_string();
                                        let mut hover = desc.clone();
                                        if !app.winget.is_empty() && app.winget != "na" {
                                            hover.push_str(&format!("\n\nwinget: {}", app.winget));
                                        }
                                        if !app.choco.is_empty() && app.choco != "na" {
                                            hover.push_str(&format!("\nchoco: {}", app.choco));
                                        }
                                        let resp = ui.checkbox(&mut app.selected, name);
                                        if !hover.is_empty() {
                                            resp.on_hover_text(&hover);
                                        }
                                        if !desc.is_empty() {
                                            let d = ui.horizontal(|ui| {
                                                ui.add_space(24.0);
                                                // Explicit wrap, not truncate: this
                                                // is the app's whole visible
                                                // description, not just a hint, so
                                                // cutting it off with an ellipsis
                                                // lost information a user needs to
                                                // pick apps by. Labels inside a
                                                // horizontal layout don't wrap on
                                                // their own.
                                                ui.add(
                                                    egui::Label::new(
                                                        egui::RichText::new(&desc)
                                                            .small()
                                                            .color(theme::subtle_text()),
                                                    )
                                                    .wrap(),
                                                )
                                            });
                                            d.inner.on_hover_text(&hover);
                                        }
                                    });
                                    if (j + 1) % cols == 0 {
                                        ui.end_row();
                                    }
                                }
                                ui.end_row();
                            });
                        i = end;
                    }
                });

                ui.add_space(8.0);
                let install_label = i18n::bundle_install_selected(lang, selected_count);
                let install_button = egui::Button::new(
                    egui::RichText::new(install_label)
                        .strong()
                        .size(17.0)
                        .color(theme::on_accent()),
                )
                .fill(if selected_count > 0 {
                    theme::accent_green()
                } else {
                    theme::accent_green_dim()
                })
                .min_size(egui::vec2(ui.available_width(), 44.0));
                if ui.add_enabled(selected_count > 0, install_button).clicked() {
                    self.spawn_install();
                }
                ui.label(
                    egui::RichText::new(t.install_console_note)
                        .small()
                        .color(theme::subtle_text()),
                );
            } else {
                // Catalog missing or unparsable: apps.json is loaded at
                // startup, so an empty list here means that load failed.
                ui.add_space(10.0);
                ui.label(
                    egui::RichText::new(format!("{} apps.json", t.bundle_load_failed_prefix))
                        .weak(),
                );
            }
            ui.add_space(16.0);
        });
    }

    /// Launches Install-Apps.ps1 for the currently selected bundle apps in a
    /// visible console so the user can watch progress.
    fn spawn_install(&mut self) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let slugs: Vec<String> = self
            .bundle_apps
            .iter()
            .filter(|a| a.selected)
            .map(|a| a.slug.clone())
            .collect();
        if slugs.is_empty() {
            return;
        }
        let script = root.join("Install-Apps.ps1");
        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
        cmd.arg(&script);
        // Comma-joined single argument; Install-Apps.ps1 splits it.
        cmd.args(["-Apps", &slugs.join(",")]);
        #[cfg(windows)]
        cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
        match cmd.spawn() {
            Ok(_) => {
                self.push_log(format!(
                    "[apps] Installing {} app(s) from pack '{}'...",
                    slugs.len(),
                    self.bundle_preset.as_deref().unwrap_or("custom")
                ));
            }
            Err(e) => self.push_error(format!("Failed to start Install-Apps.ps1: {e}")),
        }
    }

    /// "New PC" page: guided one-click setup for a fresh Windows install,
    /// with each phase explained in plain language.
    fn draw_newpc_page(&mut self, ui: &mut egui::Ui) {
        let t = self.tr();
        let lang = self.lang;
        centered_column(ui, 760.0, |ui| {
            ui.add_space(14.0);
            ui.label(egui::RichText::new(t.setup_title).size(26.0).strong());
            ui.label(egui::RichText::new(t.setup_subtitle).color(theme::subtle_text()));
            ui.add_space(10.0);

            explained_phase(ui, &mut self.newpc_restore, t.setup_restore_title, t.setup_restore_desc, |_| {});

            // The tweak/toggle selection is shared with the Optimize page,
            // so reviewing it in either place edits the same set.
            let details = t.setup_details_header;
            let caution_badge = t.optimize_caution_badge;
            let opt_tweaks = &mut self.opt_tweaks;
            explained_phase(ui, &mut self.newpc_tweaks, t.setup_tweaks_title, t.setup_tweaks_desc, |ui| {
                egui::CollapsingHeader::new(egui::RichText::new(details).small())
                    .id_salt("newpc_tweaks_details")
                    .show(ui, |ui| {
                        for (i, tw) in optimize::TWEAKS.iter().enumerate() {
                            let (title, why) = i18n::tweak_text(lang, tw.slug);
                            let badge = tw.caution.then_some(caution_badge);
                            option_row(ui, &mut opt_tweaks[i], title, why, badge);
                        }
                    });
            });

            let opt_toggles = &mut self.opt_toggles;
            explained_phase(ui, &mut self.newpc_toggles, t.setup_toggles_title, t.setup_toggles_desc, |ui| {
                egui::CollapsingHeader::new(egui::RichText::new(details).small())
                    .id_salt("newpc_toggles_details")
                    .show(ui, |ui| {
                        for (i, tg) in optimize::TOGGLES.iter().enumerate() {
                            let (title, why) = i18n::toggle_text(lang, tg.slug);
                            option_row(ui, &mut opt_toggles[i], title, why, None);
                        }
                    });
            });

            explained_phase(ui, &mut self.newpc_drivers, t.setup_drivers_title, t.setup_drivers_desc, |_| {});
            let oosu_auto = &mut self.opt_oosu_auto;
            explained_phase(ui, &mut self.newpc_oosu, t.setup_oosu_title, t.setup_oosu_desc, |ui| {
                ui.radio_value(oosu_auto, true, t.oosu_mode_auto);
                ui.radio_value(oosu_auto, false, t.oosu_mode_manual);
            });
            explained_phase(ui, &mut self.newpc_apps, t.setup_apps_title, t.setup_apps_desc, |_| {});

            ui.add_space(12.0);
            let any = self.newpc_restore
                || self.newpc_tweaks
                || self.newpc_toggles
                || self.newpc_drivers
                || self.newpc_oosu
                || self.newpc_apps;
            let enabled = any && self.root.is_some();
            let button = egui::Button::new(
                egui::RichText::new(t.setup_run_cta)
                    .strong()
                    .size(18.0)
                    .color(theme::on_accent()),
            )
            .fill(if enabled {
                theme::accent_green()
            } else {
                theme::accent_green_dim()
            })
            .min_size(egui::vec2(ui.available_width(), 48.0));
            if ui.add_enabled(enabled, button).clicked() {
                self.spawn_newpc();
            }
            ui.label(
                egui::RichText::new(t.setup_console_note)
                    .small()
                    .color(theme::subtle_text()),
            );
            ui.add_space(16.0);
        });
    }

    /// "Optimize" page: the curated winutil tweak set plus registry
    /// preferences, each with a plain-language what/why, applied headless.
    fn draw_optimize_page(&mut self, ui: &mut egui::Ui) {
        let t = self.tr();
        let lang = self.lang;
        centered_column(ui, 820.0, |ui| {
            ui.add_space(14.0);
            ui.label(egui::RichText::new(t.optimize_title).size(26.0).strong());
            ui.label(egui::RichText::new(t.optimize_subtitle).color(theme::subtle_text()));
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui.button(t.bundle_select_all).clicked() {
                    self.opt_tweaks.iter_mut().for_each(|b| *b = true);
                    self.opt_toggles.iter_mut().for_each(|b| *b = true);
                    self.opt_oosu = true;
                }
                if ui.button(t.bundle_select_none).clicked() {
                    self.opt_tweaks.iter_mut().for_each(|b| *b = false);
                    self.opt_toggles.iter_mut().for_each(|b| *b = false);
                    self.opt_oosu = false;
                }
                if ui.button(t.optimize_reset_button).clicked() {
                    self.opt_tweaks = optimize::TWEAKS.iter().map(|t| t.default_on).collect();
                    self.opt_toggles = optimize::TOGGLES.iter().map(|t| t.default_on).collect();
                    self.opt_oosu = true;
                    self.opt_oosu_auto = true;
                }
            });
            ui.add_space(8.0);

            theme::card().show(ui, |ui| {
                ui.set_min_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.strong(t.optimize_group_tweaks);
                    if ui.small_button(t.bundle_select_all).clicked() {
                        self.opt_tweaks.iter_mut().for_each(|b| *b = true);
                    }
                    if ui.small_button(t.bundle_select_none).clicked() {
                        self.opt_tweaks.iter_mut().for_each(|b| *b = false);
                    }
                });
                ui.add_space(4.0);
                let cols = option_grid_cols(ui.available_width());
                let col_w = option_grid_col_w(ui.available_width(), cols);
                egui::Grid::new("optimize_tweaks_grid")
                    .num_columns(cols)
                    .min_col_width(col_w)
                    .max_col_width(col_w)
                    .spacing([20.0, 8.0])
                    .show(ui, |ui| {
                        for (i, tw) in optimize::TWEAKS.iter().enumerate() {
                            let (title, why) = i18n::tweak_text(lang, tw.slug);
                            let badge = if tw.caution {
                                Some(t.optimize_caution_badge)
                            } else {
                                None
                            };
                            ui.vertical(|ui| {
                                option_row(ui, &mut self.opt_tweaks[i], title, why, badge);
                            });
                            if (i + 1) % cols == 0 {
                                ui.end_row();
                            }
                        }
                    });
            });

            ui.add_space(8.0);
            theme::card().show(ui, |ui| {
                ui.set_min_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.strong(t.optimize_group_toggles);
                    if ui.small_button(t.bundle_select_all).clicked() {
                        self.opt_toggles.iter_mut().for_each(|b| *b = true);
                    }
                    if ui.small_button(t.bundle_select_none).clicked() {
                        self.opt_toggles.iter_mut().for_each(|b| *b = false);
                    }
                });
                ui.add_space(4.0);
                let cols = option_grid_cols(ui.available_width());
                let col_w = option_grid_col_w(ui.available_width(), cols);
                egui::Grid::new("optimize_toggles_grid")
                    .num_columns(cols)
                    .min_col_width(col_w)
                    .max_col_width(col_w)
                    .spacing([20.0, 8.0])
                    .show(ui, |ui| {
                        for (i, tg) in optimize::TOGGLES.iter().enumerate() {
                            let (title, why) = i18n::toggle_text(lang, tg.slug);
                            ui.vertical(|ui| {
                                option_row(ui, &mut self.opt_toggles[i], title, why, None);
                            });
                            if (i + 1) % cols == 0 {
                                ui.end_row();
                            }
                        }
                    });
            });

            ui.add_space(8.0);
            theme::card().show(ui, |ui| {
                ui.set_min_width(ui.available_width());
                option_row(
                    ui,
                    &mut self.opt_oosu,
                    t.optimize_oosu_include,
                    t.optimize_oosu_desc,
                    None,
                );
                ui.add_enabled_ui(self.opt_oosu, |ui| {
                    ui.indent("oosu_mode_opt", |ui| {
                        ui.radio_value(&mut self.opt_oosu_auto, true, t.oosu_mode_auto);
                        ui.radio_value(&mut self.opt_oosu_auto, false, t.oosu_mode_manual);
                    });
                });
            });

            ui.add_space(12.0);
            let any = self.opt_oosu
                || self.opt_tweaks.iter().any(|b| *b)
                || self.opt_toggles.iter().any(|b| *b);
            let enabled = any && self.root.is_some();
            let button = egui::Button::new(
                egui::RichText::new(t.optimize_apply_cta)
                    .strong()
                    .size(18.0)
                    .color(theme::on_accent()),
            )
            .fill(if enabled {
                theme::accent_green()
            } else {
                theme::accent_green_dim()
            })
            .min_size(egui::vec2(ui.available_width(), 48.0));
            if ui.add_enabled(enabled, button).clicked() {
                self.spawn_optimize();
            }
            ui.label(
                egui::RichText::new(t.setup_console_note)
                    .small()
                    .color(theme::subtle_text()),
            );
            ui.add_space(16.0);
        });
    }

    /// Writes the winutil config generated from the shared tweak selection
    /// into Logs\ and returns its path.
    fn write_optimize_config(&self, root: &Path) -> Result<PathBuf, String> {
        let cfg_dir = root.join("Logs");
        std::fs::create_dir_all(&cfg_dir).map_err(|e| format!("Could not create Logs dir: {e}"))?;
        let cfg = cfg_dir.join("winutil-optimize.json");
        std::fs::write(&cfg, optimize::winutil_config_json(&self.opt_tweaks))
            .map_err(|e| format!("Could not write winutil config: {e}"))?;
        Ok(cfg)
    }

    /// Adds the tweak/toggle arguments shared by both setup entry points:
    /// a generated `-WinutilConfig` (or `-SkipTweaks` when the phase is off
    /// or nothing is ticked) and the `-Toggles` slug list.
    fn push_selection_args(
        &self,
        cmd: &mut Command,
        root: &Path,
        tweaks_on: bool,
        toggles_on: bool,
    ) -> Result<(), String> {
        if tweaks_on && self.opt_tweaks.iter().any(|b| *b) {
            let cfg = self.write_optimize_config(root)?;
            cmd.arg("-WinutilConfig");
            cmd.arg(cfg);
        } else {
            cmd.arg("-SkipTweaks");
        }
        let toggles = if toggles_on {
            optimize::toggles_arg(&self.opt_toggles)
        } else {
            String::new()
        };
        cmd.args(["-Toggles", &toggles]);
        Ok(())
    }

    /// Launches Setup-NewPC.ps1 for the New PC page's phase selection in a
    /// visible console (the script self-elevates via UAC). Tweaks/toggles
    /// use the granular selection shared with the Optimize page.
    fn spawn_newpc(&mut self) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let script = root.join("Setup-NewPC.ps1");
        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
        cmd.arg(&script);
        if !self.newpc_restore {
            cmd.arg("-SkipRestorePoint");
        }
        if !self.newpc_drivers {
            cmd.arg("-SkipDrivers");
        }
        if !self.newpc_apps {
            cmd.arg("-SkipApps");
        }
        if self.newpc_oosu {
            cmd.args(["-Oosu", "-OosuMode"]);
            cmd.arg(if self.opt_oosu_auto { "auto" } else { "manual" });
        }
        if let Err(e) = self.push_selection_args(
            &mut cmd,
            &root,
            self.newpc_tweaks,
            self.newpc_toggles,
        ) {
            self.push_error(e);
            return;
        }
        #[cfg(windows)]
        cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
        match cmd.spawn() {
            Ok(_) => self.push_log("[setup] New PC setup started in its own window.".to_string()),
            Err(e) => self.push_error(format!("Failed to start Setup-NewPC.ps1: {e}")),
        }
    }

    /// Launches Setup-NewPC.ps1 with only the tweak/toggle/OOSU phases, using
    /// a winutil config generated from the Optimize page's selection.
    fn spawn_optimize(&mut self) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let script = root.join("Setup-NewPC.ps1");
        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
        cmd.arg(&script);
        cmd.args(["-SkipDrivers", "-SkipApps"]);
        if self.opt_oosu {
            cmd.args(["-Oosu", "-OosuMode"]);
            cmd.arg(if self.opt_oosu_auto { "auto" } else { "manual" });
        }
        if let Err(e) = self.push_selection_args(&mut cmd, &root, true, true) {
            self.push_error(e);
            return;
        }
        #[cfg(windows)]
        cmd.creation_flags(engine::CREATE_NEW_CONSOLE);
        match cmd.spawn() {
            Ok(_) => {
                self.push_log("[setup] Optimization run started in its own window.".to_string());
            }
            Err(e) => self.push_error(format!("Failed to start Setup-NewPC.ps1: {e}")),
        }
    }

    fn draw_pins_tab(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        ui.label(egui::RichText::new(t.pins_intro).weak());
        ui.add_space(6.0);

        egui::ScrollArea::vertical()
            .max_height(300.0)
            .show(ui, |ui| {
                egui_extras::TableBuilder::new(ui)
                    .striped(true)
                    .column(egui_extras::Column::remainder().at_least(200.0))
                    .column(egui_extras::Column::initial(122.0).at_least(84.0))
                    .column(egui_extras::Column::initial(72.0).at_least(52.0))
                    .header(20.0, |mut header| {
                        header.col(|ui| {
                            ui.strong(t.pins_col_package_id);
                        });
                        header.col(|ui| {
                            ui.strong(t.pins_col_manager);
                        });
                        header.col(|ui| {
                            ui.strong("");
                        });
                    })
                    .body(|mut body| {
                        let mut to_remove: Option<usize> = None;
                        for (i, pin) in self.pins.iter().enumerate() {
                            body.row(20.0, |mut row| {
                                row.col(|ui| {
                                    ui.label(&pin.id);
                                });
                                row.col(|ui| {
                                    ui.label(pin.manager.as_str());
                                });
                                row.col(|ui| {
                                    if ui.small_button(t.pins_delete).clicked() {
                                        to_remove = Some(i);
                                    }
                                });
                            });
                        }
                        if let Some(i) = to_remove {
                            self.pins.remove(i);
                            self.pin_save_msg = None;
                        }
                    });
            });

        ui.add_space(8.0);
        ui.horizontal(|ui| {
            ui.label(t.pins_new_label);
            ui.text_edit_singleline(&mut self.new_pin_id);
            egui::ComboBox::from_id_salt("new_pin_manager")
                .selected_text(self.new_pin_manager.as_str())
                .show_ui(ui, |ui| {
                    ui.selectable_value(&mut self.new_pin_manager, Manager::Winget, "winget");
                    ui.selectable_value(&mut self.new_pin_manager, Manager::Choco, "choco");
                });
            if ui.button(t.pins_add).clicked() {
                let id = self.new_pin_id.trim().to_string();
                match pins::validate_pin_id(&id, self.new_pin_manager, &self.pins) {
                    Ok(()) => {
                        self.pins.push(PinEntry {
                            id,
                            manager: self.new_pin_manager,
                        });
                        self.new_pin_id.clear();
                        self.pin_error = None;
                        self.pin_save_msg = None;
                    }
                    Err(e) => self.pin_error = Some(e),
                }
            }
        });

        if let Some(err) = &self.pin_error {
            ui.colored_label(theme::status_error(), err);
        }

        // Pick from installed packages instead of typing the id by hand.
        ui.add_space(10.0);
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new(t.pins_detect_hint).weak());
            if ui
                .add_enabled(
                    !self.installed_loading,
                    egui::Button::new(t.pins_detect_button),
                )
                .clicked()
            {
                self.refresh_installed(ctx);
            }
            if self.installed_loading {
                ui.add(egui::Spinner::new().size(12.0));
                ui.label(egui::RichText::new(t.pins_detect_loading).small().weak());
            }
        });
        if !self.installed_apps.is_empty() {
            ui.horizontal(|ui| {
                ui.label(t.filter_label);
                ui.text_edit_singleline(&mut self.pin_filter);
            });
            let filter = self.pin_filter.to_lowercase();
            let mut to_add: Option<(String, Manager)> = None;
            egui::ScrollArea::vertical()
                .id_salt("pin_picker_scroll")
                .max_height(220.0)
                .show(ui, |ui| {
                    for app in &self.installed_apps {
                        if !filter.is_empty()
                            && !app.id.to_lowercase().contains(&filter)
                            && !app.name.to_lowercase().contains(&filter)
                        {
                            continue;
                        }
                        let already =
                            self.pins.iter().any(|p| {
                                p.manager == app.manager && p.id.eq_ignore_ascii_case(&app.id)
                            });
                        ui.horizontal(|ui| {
                            if ui
                                .add_enabled(!already, egui::Button::new(t.pins_add).small())
                                .clicked()
                            {
                                to_add = Some((app.id.clone(), app.manager));
                            }
                            ui.label(&app.name);
                            ui.label(
                                egui::RichText::new(format!(
                                    "{} \u{b7} {}",
                                    app.id,
                                    app.manager.as_str()
                                ))
                                .small()
                                .color(theme::subtle_text()),
                            );
                        });
                    }
                });
            if let Some((id, manager)) = to_add {
                match pins::validate_pin_id(&id, manager, &self.pins) {
                    Ok(()) => {
                        self.pins.push(PinEntry { id, manager });
                        self.pin_error = None;
                        self.pin_save_msg = None;
                    }
                    Err(e) => self.pin_error = Some(e),
                }
            }
        }

        ui.add_space(8.0);
        if ui.button(t.pins_save).clicked() {
            self.save_pins();
        }
        if let Some(msg) = &self.pin_save_msg {
            ui.colored_label(theme::status_ok(), msg);
        }
    }

    fn draw_driver_store_tab(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        ui.label(egui::RichText::new(t.drivers_intro).weak());
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.drivers_loading, egui::Button::new(t.drivers_refresh))
                .clicked()
            {
                self.refresh_drivers(ctx);
            }
            // Updating drivers belongs on the page about drivers, not only on
            // the Tools page. Same action as the Tools button.
            if ui.button(t.drivers_update_btn).clicked() {
                self.launch_sdio();
            }
            if self.drivers_loading {
                ui.add(egui::Spinner::new());
                ui.label(t.drivers_querying);
            }
            if let Some(err) = &self.drivers_error {
                ui.colored_label(theme::status_error(), err);
            }
        });
        ui.label(egui::RichText::new(t.drivers_update_hint).weak().small());
        ui.add_space(6.0);

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                egui_extras::TableBuilder::new(ui)
                    .striped(true)
                    .column(egui_extras::Column::initial(180.0).at_least(120.0))
                    .column(egui_extras::Column::initial(140.0).at_least(100.0))
                    .column(egui_extras::Column::remainder().at_least(140.0))
                    .column(egui_extras::Column::initial(100.0).at_least(80.0))
                    .header(20.0, |mut header| {
                        header.col(|ui| {
                            ui.strong(t.drivers_col_published_name);
                        });
                        header.col(|ui| {
                            ui.strong(t.drivers_col_class);
                        });
                        header.col(|ui| {
                            ui.strong(t.drivers_col_version);
                        });
                        header.col(|ui| {
                            ui.strong(t.drivers_col_date);
                        });
                    })
                    .body(|body| {
                        let drivers = &self.drivers;
                        body.rows(20.0, drivers.len(), |mut row| {
                            let d = &drivers[row.index()];
                            row.col(|ui| {
                                ui.label(&d.published_name);
                            });
                            row.col(|ui| {
                                ui.label(&d.class_name);
                            });
                            row.col(|ui| {
                                ui.label(&d.driver_version);
                            });
                            row.col(|ui| {
                                ui.label(&d.driver_date);
                            });
                        });
                    });
            });
    }

    fn draw_services_section(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        if !self.services_fetched {
            self.refresh_services(ctx);
        }
        ui.label(egui::RichText::new(t.services_intro).weak());
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.services_loading, egui::Button::new(t.drivers_refresh))
                .clicked()
            {
                self.refresh_services(ctx);
            }
            if ui.button(t.services_open_console).clicked() {
                open_windows_target("services.msc");
            }
            if self.services_loading {
                ui.add(egui::Spinner::new());
                ui.label(t.services_loading);
            }
            if let Some(err) = &self.services_error {
                ui.colored_label(theme::status_error(), err);
            }
            ui.label(t.filter_label);
            ui.text_edit_singleline(&mut self.services_filter);
        });
        ui.add_space(6.0);

        let show_advanced = self.system_show_advanced;
        // For services, "protected" = marked keep OR not in the KB at all:
        // unidentified services are mostly core Windows plumbing, exactly
        // what a non-expert should not be toggling.
        let is_protected = |s: &ServiceEntry| {
            !matches!(
                advice::service_advice(&s.name, &s.display_name).map(|e| e.advice),
                Some(Advice::Optional) | Some(Advice::SafeOff)
            )
        };
        let hidden_count = if show_advanced {
            0
        } else {
            self.services.iter().filter(|s| is_protected(s)).count()
        };
        if hidden_count > 0 {
            ui.label(
                egui::RichText::new(i18n::hidden_items(self.lang, hidden_count))
                    .small()
                    .color(theme::subtle_text()),
            );
        }
        let filter = self.services_filter.to_lowercase();
        let mut rows: Vec<(ServiceEntry, Option<f64>)> = self
            .services
            .iter()
            .filter(|s| show_advanced || !is_protected(s))
            .filter(|s| {
                filter.is_empty()
                    || s.name.to_lowercase().contains(&filter)
                    || s.display_name.to_lowercase().contains(&filter)
            })
            .map(|s| {
                let secs = system::boot_time_for(&self.boot_times, &s.display_name)
                    .or_else(|| system::boot_time_for(&self.boot_times, &s.name));
                (s.clone(), secs)
            })
            .collect();
        let mut sort = self.services_sort;
        rows.sort_by(|(a, ta), (b, tb)| {
            let ord = match sort.field {
                SortField::Display => a
                    .display_name
                    .to_lowercase()
                    .cmp(&b.display_name.to_lowercase()),
                SortField::Advice => {
                    advice_sort_rank(advice::service_advice(&a.name, &a.display_name)).cmp(
                        &advice_sort_rank(advice::service_advice(&b.name, &b.display_name)),
                    )
                }
                SortField::Status => a.state.cmp(&b.state),
                SortField::StartMode => a.start_mode.cmp(&b.start_mode),
                SortField::Time => cmp_time(*ta, *tb),
                _ => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            if sort.asc {
                ord
            } else {
                ord.reverse()
            }
        });
        let lang = self.lang;
        let busy = self.service_busy.clone();
        let mut change: Option<(String, &'static str)> = None;

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                egui_extras::TableBuilder::new(ui)
                    .striped(true)
                    .column(egui_extras::Column::initial(240.0).at_least(150.0))
                    .column(egui_extras::Column::remainder().at_least(200.0))
                    .column(egui_extras::Column::initial(148.0).at_least(96.0))
                    .column(egui_extras::Column::initial(70.0).at_least(52.0))
                    .column(egui_extras::Column::initial(90.0).at_least(70.0))
                    .column(egui_extras::Column::initial(130.0).at_least(120.0))
                    .header(20.0, |mut header| {
                        header.col(|ui| {
                            sort_header(ui, t.services_col_display, SortField::Display, &mut sort);
                        });
                        header.col(|ui| {
                            ui.strong(t.what_col);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.advice_col, SortField::Advice, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.time_col, SortField::Time, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.services_col_state, SortField::Status, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.services_col_start, SortField::StartMode, &mut sort);
                        });
                    })
                    .body(|body| {
                        body.rows(22.0, rows.len(), |mut row| {
                            let (s, secs) = &rows[row.index()];
                            row.col(|ui| {
                                ui.add(egui::Label::new(&s.display_name).truncate())
                                    .on_hover_text(format!(
                                        "{} ({})\n\n{}",
                                        s.display_name, s.name, s.description
                                    ));
                            });
                            row.col(|ui| {
                                // Curated note when known, else Windows' own
                                // (localized) service description.
                                let what = match advice::service_advice(&s.name, &s.display_name)
                                {
                                    Some(e) => e.note(lang).to_string(),
                                    None => s.description.clone(),
                                };
                                ui.add(
                                    egui::Label::new(
                                        egui::RichText::new(&what)
                                            .small()
                                            .color(theme::subtle_text()),
                                    )
                                    .truncate(),
                                )
                                .on_hover_text(if s.description.is_empty() {
                                    what.clone()
                                } else {
                                    format!("{what}\n\n{}", s.description)
                                });
                            });
                            row.col(|ui| {
                                advice_badge(
                                    ui,
                                    t,
                                    lang,
                                    advice::service_advice(&s.name, &s.display_name),
                                );
                            });
                            row.col(|ui| {
                                time_cell(ui, *secs);
                            });
                            row.col(|ui| {
                                let color = if s.state.eq_ignore_ascii_case("running") {
                                    theme::status_ok()
                                } else {
                                    theme::subtle_text()
                                };
                                ui.colored_label(color, &s.state);
                            });
                            row.col(|ui| {
                                let this_busy = busy.as_deref() == Some(s.name.as_str());
                                ui.add_enabled_ui(busy.is_none(), |ui| {
                                    let label = if this_busy { "..." } else { &s.start_mode };
                                    egui::ComboBox::from_id_salt(format!("svc_{}", s.name))
                                        .selected_text(label)
                                        .width(110.0)
                                        .show_ui(ui, |ui| {
                                            for (mode, shown) in [
                                                ("Automatic", "Auto"),
                                                ("Manual", "Manual"),
                                                ("Disabled", "Disabled"),
                                            ] {
                                                let is = s.start_mode.eq_ignore_ascii_case(shown)
                                                    || s.start_mode.eq_ignore_ascii_case(mode);
                                                if ui.selectable_label(is, shown).clicked() && !is {
                                                    change = Some((s.name.clone(), mode));
                                                }
                                            }
                                        });
                                });
                            });
                        });
                    });
            });

        self.services_sort = sort;

        if let Some((name, mode)) = change {
            self.spawn_set_service(ctx, name, mode);
        }
    }

    fn draw_startup_section(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let t = self.tr();
        if !self.autostart_fetched {
            self.refresh_startup(ctx);
        }
        ui.label(egui::RichText::new(t.startup_intro).weak());
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.autostart_loading, egui::Button::new(t.drivers_refresh))
                .clicked()
            {
                self.refresh_startup(ctx);
            }
            if ui.button(t.startup_open_settings).clicked() {
                open_windows_target("ms-settings:startupapps");
            }
            if self.autostart_loading {
                ui.add(egui::Spinner::new());
                ui.label(t.startup_loading);
            }
            if let Some(err) = &self.autostart_error {
                ui.colored_label(theme::status_error(), err);
            }
            ui.label(t.filter_label);
            ui.text_edit_singleline(&mut self.autostart_filter);
        });
        ui.add_space(6.0);

        let lang = self.lang;
        let show_advanced = self.system_show_advanced;
        let is_protected = |s: &StartupEntry| {
            matches!(
                advice::startup_advice(&s.name, &s.command).map(|e| e.advice),
                Some(Advice::Keep)
            )
        };
        let hidden_count = if show_advanced {
            0
        } else {
            self.autostart_entries.iter().filter(|s| is_protected(s)).count()
        };
        if hidden_count > 0 {
            ui.label(
                egui::RichText::new(i18n::hidden_items(lang, hidden_count))
                    .small()
                    .color(theme::subtle_text()),
            );
        }
        let filter = self.autostart_filter.to_lowercase();
        let mut rows: Vec<(StartupEntry, Option<f64>)> = self
            .autostart_entries
            .iter()
            .filter(|s| show_advanced || !is_protected(s))
            .filter(|s| {
                filter.is_empty()
                    || s.name.to_lowercase().contains(&filter)
                    || s.command.to_lowercase().contains(&filter)
            })
            .map(|s| {
                let secs = system::boot_time_for(&self.boot_times, &s.name);
                (s.clone(), secs)
            })
            .collect();
        let mut sort = self.autostart_sort;
        rows.sort_by(|(a, ta), (b, tb)| {
            let ord = match sort.field {
                // asc = enabled first ("On" on top).
                SortField::Status => b.enabled.cmp(&a.enabled),
                SortField::Advice => advice_sort_rank(advice::startup_advice(&a.name, &a.command))
                    .cmp(&advice_sort_rank(advice::startup_advice(&b.name, &b.command))),
                SortField::Time => cmp_time(*ta, *tb),
                _ => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            if sort.asc {
                ord
            } else {
                ord.reverse()
            }
        });
        let busy = self.autostart_busy.clone();
        let mut toggle: Option<StartupEntry> = None;

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                egui_extras::TableBuilder::new(ui)
                    .striped(true)
                    .column(egui_extras::Column::initial(108.0).at_least(72.0))
                    .column(egui_extras::Column::initial(148.0).at_least(96.0))
                    .column(egui_extras::Column::initial(70.0).at_least(52.0))
                    .column(egui_extras::Column::initial(200.0).at_least(120.0))
                    .column(egui_extras::Column::remainder().at_least(220.0))
                    .header(20.0, |mut header| {
                        header.col(|ui| {
                            sort_header(ui, t.startup_col_enabled, SortField::Status, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.advice_col, SortField::Advice, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.time_col, SortField::Time, &mut sort);
                        });
                        header.col(|ui| {
                            sort_header(ui, t.startup_col_name, SortField::Name, &mut sort);
                        });
                        header.col(|ui| {
                            ui.strong(t.what_col);
                        });
                    })
                    .body(|body| {
                        body.rows(24.0, rows.len(), |mut row| {
                            let (s, secs) = &rows[row.index()];
                            row.col(|ui| {
                                if !s.can_toggle() {
                                    ui.label(
                                        egui::RichText::new(t.startup_once_label)
                                            .small()
                                            .color(theme::subtle_text()),
                                    )
                                    .on_hover_text(t.startup_once_hover);
                                    return;
                                }
                                let this_busy = busy.as_deref() == Some(s.name.as_str());
                                let (label, color) = if this_busy {
                                    ("...", theme::subtle_text())
                                } else if s.enabled {
                                    (t.startup_on, theme::accent_green())
                                } else {
                                    (t.startup_off, theme::subtle_text())
                                };
                                let button = egui::Button::new(
                                    egui::RichText::new(label).strong().color(color),
                                )
                                .min_size(egui::vec2(72.0, 20.0));
                                if ui
                                    .add_enabled(busy.is_none(), button)
                                    .on_hover_text(t.startup_toggle_hover)
                                    .clicked()
                                {
                                    toggle = Some(s.clone());
                                }
                            });
                            row.col(|ui| {
                                advice_badge(ui, t, lang, advice::startup_advice(&s.name, &s.command));
                            });
                            row.col(|ui| {
                                time_cell(ui, *secs);
                            });
                            row.col(|ui| {
                                let text = if s.enabled {
                                    egui::RichText::new(&s.name)
                                } else {
                                    egui::RichText::new(&s.name)
                                        .strikethrough()
                                        .color(theme::subtle_text())
                                };
                                ui.add(egui::Label::new(text).truncate())
                                    .on_hover_text(&s.location);
                            });
                            row.col(|ui| {
                                // Curated note when known, otherwise say what
                                // program it launches; full command on hover.
                                let what = match advice::startup_advice(&s.name, &s.command) {
                                    Some(e) => e.note(lang).to_string(),
                                    None => i18n::runs_at_signin(
                                        lang,
                                        &system::exe_name(&s.command),
                                    ),
                                };
                                ui.add(
                                    egui::Label::new(
                                        egui::RichText::new(&what)
                                            .small()
                                            .color(theme::subtle_text()),
                                    )
                                    .truncate(),
                                )
                                .on_hover_text(format!("{what}\n\n{}", s.command));
                            });
                        });
                    });
            });
        self.autostart_sort = sort;

        if let Some(entry) = toggle {
            self.spawn_toggle_startup(ctx, entry);
        }
    }

    /// Generates StartupReport.md (Export-StartupReport.ps1) hidden in the
    /// background and opens it when done.
    fn spawn_export_report(&mut self) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let script = root.join("Export-StartupReport.ps1");
        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
        cmd.arg(&script);
        cmd.arg("-Open");
        #[cfg(windows)]
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        match cmd.spawn() {
            Ok(_) => self.push_log(
                "[system] Generating StartupReport.md - it will open when ready.".to_string(),
            ),
            Err(e) => self.push_error(format!("Failed to start report export: {e}")),
        }
    }

    /// Applies a startup on/off toggle in the background, then re-queries
    /// the list so the UI reflects reality rather than an assumption.
    fn spawn_toggle_startup(&mut self, ctx: &egui::Context, entry: StartupEntry) {
        self.autostart_busy = Some(entry.name.clone());
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result =
                system::set_startup_enabled(&entry.approved_key, &entry.approved_name, !entry.enabled);
            if let Err(e) = result {
                let _ = tx.send(AppEvent::Error(format!(
                    "Startup toggle '{}' failed: {e}",
                    entry.name
                )));
            }
            let list = system::query_startup(Duration::from_secs(60));
            let _ = tx.send(AppEvent::StartupList(list));
            ctx.request_repaint();
        });
    }

    /// Changes a service's start type in the background, then re-queries.
    fn spawn_set_service(&mut self, ctx: &egui::Context, name: String, mode: &'static str) {
        self.service_busy = Some(name.clone());
        let tx = self.tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            if let Err(e) = system::set_service_start_mode(&name, mode) {
                let _ = tx.send(AppEvent::Error(format!(
                    "Set-Service '{name}' -> {mode} failed: {e}"
                )));
            }
            let list = system::query_services(Duration::from_secs(60));
            let _ = tx.send(AppEvent::ServiceList(list));
            ctx.request_repaint();
        });
    }

    fn draw_reboot_dialog(&mut self, ctx: &egui::Context) {
        if !self.show_reboot_confirm {
            return;
        }
        let t = self.tr();
        let mut open = true;
        let mut proceed = false;
        let mut cancel = false;
        egui::Window::new(t.reboot_dialog_title)
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.label(t.reboot_dialog_body);
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.button(t.reboot_dialog_proceed).clicked() {
                        proceed = true;
                    }
                    if ui.button(t.reboot_dialog_cancel).clicked() {
                        cancel = true;
                    }
                });
            });
        if proceed {
            self.show_reboot_confirm = false;
            self.start_run(ctx, true);
        } else if cancel || !open {
            self.show_reboot_confirm = false;
        }
    }

    fn draw_nvclean_help(&mut self, ctx: &egui::Context) {
        if !self.nvclean_help_open {
            return;
        }
        let t = self.tr();
        let mut open = true;
        let mut launch = false;
        egui::Window::new(t.nvclean_help_title)
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.label(t.nvclean_help_intro);
                ui.add_space(6.0);
                ui.label(t.nvclean_help_step1);
                ui.label(t.nvclean_help_step2);
                ui.label(t.nvclean_help_step3);
                ui.label(t.nvclean_help_step4);
                ui.label(t.nvclean_help_step5);
                ui.label(t.nvclean_help_step6);
                ui.add_space(8.0);
                if ui.button(t.nvclean_help_open_now).clicked() {
                    launch = true;
                }
            });
        if launch {
            let path = self.settings.nvclean_path.clone();
            if path.is_empty() || !Path::new(&path).is_file() {
                self.push_error("NVCleanPath is not configured or the file does not exist.");
            } else if let Err(e) = spawn_detached(Path::new(&path), &[]) {
                self.push_error(format!("Failed to launch NVCleanstall: {e}"));
            }
            self.nvclean_help_open = false;
        } else if !open {
            self.nvclean_help_open = false;
        }
    }
}

/// Does a raw summary value from the engine mean "this went fine"?
///
/// Shared by `finalize_categories` (status chips, banner, toast) and the
/// Summary tab, which used to test `== "ok"` on its own. The engine emits
/// qualified values like `ok - some steps failed, see log (exit 1)` when a
/// single topgrade step failed, and the two rules disagreeing meant the same
/// run showed a green chip and a red Summary row at the same time.
fn summary_value_is_ok(v: &str) -> bool {
    let v = v.trim().to_lowercase();
    v == "ok" || v.starts_with("ok ") || v.starts_with("ok-") || v == "reinstalled"
}

/// Values meaning "this step didn't run", as opposed to succeeded or failed.
fn summary_value_is_skipped(v: &str) -> bool {
    matches!(v.trim().to_lowercase().as_str(), "skipped" | "n/a")
}

/// Neither a failure: `benign` in the old `finalize_categories` sense.
fn summary_value_is_benign(v: &str) -> bool {
    summary_value_is_ok(v) || summary_value_is_skipped(v)
}

/// A page/section tab. The selected one gets a solid accent pill with
/// on-accent text.
///
/// It used to draw accent-GREEN text over `Button::selectable`'s highlight,
/// which is filled from `visuals.selection.bg_fill` -- also green. Green on
/// green left the label of the *currently open* tab almost unreadable in both
/// themes, which is the one label that most needs to be legible.
fn tab_button(ui: &mut egui::Ui, selected: bool, label: &str, size: f32) -> egui::Response {
    let text = egui::RichText::new(label).size(size);
    let resp = if selected {
        ui.add(
            egui::Button::new(text.strong().color(theme::on_accent()))
                .fill(theme::accent_green()),
        )
    } else {
        ui.add(egui::Button::selectable(false, text))
    };
    ui.add_space(4.0);
    resp
}

/// Advice for a scheduled task.
///
/// A task is identifiable by the executable it runs OR by its folder path,
/// and `STARTUP_KB` holds patterns keyed off both. The command is tried
/// first because it is the more specific of the two.
///
/// Deliberately two calls rather than one against `"{path} {command}"`:
/// `startup_advice` matches patterns against the whole joined string, so a
/// concatenation lets a pattern match across the boundary between the two
/// fields and report advice for something neither field actually says.
fn task_advice(task: &TaskEntry) -> Option<&'static advice::AdviceEntry> {
    advice::startup_advice(&task.name, &task.command)
        .or_else(|| advice::startup_advice(&task.name, &task.path))
}

fn extract_tag(line: &str) -> (Option<&str>, bool) {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            let tag = &rest[..end];
            let is_warn = theme::is_warning_tag(tag);
            return (Some(tag), is_warn);
        }
    }
    (None, false)
}

fn format_duration(d: Duration) -> String {
    let total = d.as_secs();
    format!(
        "{:02}:{:02}:{:02}",
        total / 3600,
        (total % 3600) / 60,
        total % 60
    )
}

/// One setup-phase card on the New PC page: checkbox, title, plain-language
/// description, plus optional extra content (e.g. a collapsible detail list).
/// The WHOLE card is a click target (interactive children still win their
/// own clicks), so nobody has to aim for the small checkbox.
fn explained_phase(
    ui: &mut egui::Ui,
    checked: &mut bool,
    title: &str,
    desc: &str,
    extra: impl FnOnce(&mut egui::Ui),
) {
    let frame = if *checked {
        theme::card_selected()
    } else {
        theme::card()
    };
    frame.show(ui, |ui| {
        ui.set_min_width(ui.available_width());
        ui.set_min_height(48.0);
        ui.horizontal_top(|ui| {
            ui.checkbox(checked, "");
            ui.vertical(|ui| {
                // Title and description are click targets too — but NOT the
                // whole card: a full-frame interact would steal clicks from
                // the collapsible list / radio buttons inside `extra`.
                let text = if *checked {
                    egui::RichText::new(title)
                        .size(16.0)
                        .strong()
                        .color(theme::accent_green())
                } else {
                    egui::RichText::new(title).size(16.0).strong()
                };
                let title_resp = ui.add(egui::Label::new(text).sense(egui::Sense::click()));
                let desc_resp = ui.add(
                    egui::Label::new(egui::RichText::new(desc).small().color(theme::subtle_text()))
                        .sense(egui::Sense::click()),
                );
                if title_resp.hovered() || desc_resp.hovered() {
                    ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                }
                if title_resp.clicked() || desc_resp.clicked() {
                    *checked = !*checked;
                }
                extra(ui);
            });
        });
    });
}

/// How many columns an optimize-page checklist should use for the given
/// available width. Each item carries a full explanatory sentence (unlike
/// the short app names in the Install Apps grid), so this stays narrower --
/// capped at 2 -- rather than growing to 3-4 the way that grid does; a third
/// column would squeeze the "why" text into an uncomfortably narrow wrap.
fn option_grid_cols(available_w: f32) -> usize {
    if available_w >= 760.0 {
        2
    } else {
        1
    }
}

/// Column width for `option_grid_cols`, accounting for the grid's own
/// inter-column spacing.
fn option_grid_col_w(available_w: f32, cols: usize) -> f32 {
    ((available_w - 20.0 * (cols as f32 - 1.0)) / cols as f32).max(300.0)
}

/// One optimization row: the checkbox carries the title as its label (so
/// clicking the text toggles too), with the plain-language "why" underneath.
fn option_row(
    ui: &mut egui::Ui,
    checked: &mut bool,
    title: &str,
    why: &str,
    caution_badge: Option<&str>,
) {
    ui.horizontal(|ui| {
        let text = if *checked {
            egui::RichText::new(title).strong().color(theme::accent_green())
        } else {
            egui::RichText::new(title).strong()
        };
        ui.checkbox(checked, text);
        if let Some(badge) = caution_badge {
            ui.label(egui::RichText::new(badge).small().color(theme::warn_amber()));
        }
    });
    ui.horizontal(|ui| {
        ui.add_space(24.0);
        // Explicit wrap: labels inside a horizontal layout don't wrap on
        // their own, which let long explanations stretch the whole card.
        ui.add(
            egui::Label::new(egui::RichText::new(why).small().color(theme::subtle_text()))
                .wrap(),
        );
    });
    ui.add_space(4.0);
}

/// One selectable update-category card: checkbox, friendly title, one-line
/// description and a status chip.
fn category_row(
    ui: &mut egui::Ui,
    t: &Strings,
    checked: &mut bool,
    status: Status,
    title: &str,
    desc: &str,
    enabled: bool,
) {
    let frame = if *checked && enabled {
        theme::card_selected()
    } else {
        theme::card()
    };
    let resp = frame
        .show(ui, |ui| {
            ui.set_min_height(48.0);
            ui.add_enabled_ui(enabled, |ui| {
                ui.horizontal_top(|ui| {
                    ui.checkbox(checked, "");
                    // Reserve a fixed slot for the status chip so the text
                    // column has the same width in every card. Sized for the
                    // longest status word across languages ("executando"/
                    // "ignorado" in pt-BR run longer than their English
                    // counterparts), plus the spinner shown while running.
                    let chip_w = 112.0;
                    ui.vertical(|ui| {
                        ui.set_width((ui.available_width() - chip_w).max(0.0));
                        ui.label(egui::RichText::new(title).size(16.0).strong());
                        ui.label(egui::RichText::new(desc).small().color(theme::subtle_text()));
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::TOP), |ui| {
                        status_chip(ui, t, status);
                    });
                });
            });
        })
        .response
        .interact(egui::Sense::click());
    if enabled && resp.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    if enabled && resp.clicked() {
        *checked = !*checked;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn milestones_are_monotonic_and_end_at_100() {
        for (wu, store, apps, steam) in [
            (true, true, true, true),
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, true),
            (false, false, true, false),
        ] {
            let plan = build_milestones(wu, store, apps, steam);
            assert!(!plan.is_empty());
            let mut prev_end = 0.0_f32;
            for m in &plan {
                assert!(m.start >= prev_end - 0.001, "monotonic starts: {plan:?}");
                assert!(m.end > m.start, "non-empty span: {plan:?}");
                prev_end = m.end;
            }
            assert!(
                (plan.last().unwrap().end - 100.0).abs() < 0.001,
                "normalized to 100: {plan:?}"
            );
        }
    }

    #[test]
    fn milestones_skip_unchecked_categories() {
        let plan = build_milestones(true, false, false, false);
        assert!(plan.iter().all(|m| m.tag != "store" && m.tag != "winget"));
        assert!(plan.iter().any(|m| m.tag == "winupdate"));
    }

    #[test]
    fn parse_counter_reads_winget_progress() {
        assert_eq!(parse_counter("(1/6) Found Subtitle Edit"), Some((1, 6)));
        assert_eq!(parse_counter("  (12/30) Found X"), Some((12, 30)));
        assert_eq!(parse_counter("no counter here"), None);
        assert_eq!(parse_counter("(abc/def) nope"), None);
        assert_eq!(parse_counter("(1) nope"), None);
    }
}
