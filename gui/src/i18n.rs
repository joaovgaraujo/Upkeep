//! Minimal, compile-time-checked i18n layer.
//!
//! Every user-visible piece of UI *chrome* (window/tab/button/label text,
//! status chips, dialogs, toast, tips) is a field on [`Strings`], with one
//! `static` instance per [`Lang`]. Because these are plain struct fields
//! (not stringly-typed lookup keys), a typo or a missing translation is a
//! compile error rather than a silent runtime fallback.
//!
//! Deliberately NOT routed through here (kept exactly as today, in both
//! languages):
//! - Technical/product terms: winget, choco, topgrade, Windows Update, pins,
//!   SDIO, RAPR, NVCleanstall, winutil, JDownloader, EA app, log tags like
//!   `[winget]`.
//! - The engine's own log output, and any app-generated diagnostic text that
//!   lands in the same log pane (`push_log`/`push_error` message bodies) --
//!   that stream is inherently mixed English/technical content sourced from
//!   the .bat script itself, so it is left as-is rather than partially
//!   translated.
//! - Raw summary values parsed from the engine (`ok`, `skipped`, `n/a`, ...)
//!   -- these are engine output, not GUI chrome.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    En,
    PtBr,
}

impl Lang {
    /// Parses a `settings.json` "Language" value ("en" / "pt-BR"), defaulting
    /// to English for anything unrecognized.
    pub fn from_code(code: &str) -> Self {
        match code {
            "pt-BR" | "pt-br" | "pt_BR" | "pt" => Lang::PtBr,
            _ => Lang::En,
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::PtBr => "pt-BR",
        }
    }
}

pub struct Strings {
    // -- Navigation / pages ---------------------------------------------------
    pub tagline: &'static str,
    pub nav_update: &'static str,
    pub nav_install: &'static str,
    pub nav_newpc: &'static str,
    pub nav_optimize: &'static str,
    pub nav_system: &'static str,
    pub nav_tools: &'static str,
    pub nav_advanced: &'static str,

    // -- Update page ----------------------------------------------------------
    pub update_title: &'static str,
    pub update_subtitle: &'static str,
    pub cat_windows_update_desc: &'static str,
    pub cat_store_desc: &'static str,
    pub cat_apps_desc: &'static str,
    pub cat_steam_desc: &'static str,
    pub run_cta: &'static str,
    pub stop_cta: &'static str,
    pub stopping_button: &'static str,
    pub view_full_log: &'static str,
    pub result_ok_title: &'static str,
    pub result_issues_title: &'static str,
    pub result_no_summary_title: &'static str,

    // -- Install Apps page ------------------------------------------------------
    pub install_title: &'static str,
    pub install_subtitle: &'static str,
    pub install_step2_hint: &'static str,
    pub install_console_note: &'static str,
    pub pack_basic_name: &'static str,
    pub pack_basic_desc: &'static str,
    pub pack_dev_name: &'static str,
    pub pack_dev_desc: &'static str,
    pub pack_full_name: &'static str,
    pub pack_full_desc: &'static str,
    pub pack_generic_desc: &'static str,
    pub pack_apps_suffix: &'static str,

    // -- New PC page ------------------------------------------------------------
    pub setup_title: &'static str,
    pub setup_subtitle: &'static str,
    pub setup_run_cta: &'static str,
    pub setup_console_note: &'static str,
    pub setup_details_header: &'static str,
    pub setup_restore_title: &'static str,
    pub setup_restore_desc: &'static str,
    pub setup_tweaks_title: &'static str,
    pub setup_tweaks_desc: &'static str,
    pub setup_toggles_title: &'static str,
    pub setup_toggles_desc: &'static str,
    pub setup_drivers_title: &'static str,
    pub setup_drivers_desc: &'static str,
    pub setup_oosu_title: &'static str,
    pub setup_oosu_desc: &'static str,
    pub setup_apps_title: &'static str,
    pub setup_apps_desc: &'static str,

    // -- Optimize page ------------------------------------------------------------
    pub optimize_title: &'static str,
    pub optimize_subtitle: &'static str,
    pub optimize_group_tweaks: &'static str,
    pub optimize_group_toggles: &'static str,
    pub optimize_caution_badge: &'static str,
    pub optimize_apply_cta: &'static str,
    pub optimize_reset_button: &'static str,
    pub optimize_oosu_include: &'static str,
    pub optimize_oosu_desc: &'static str,
    pub oosu_mode_auto: &'static str,
    pub oosu_mode_manual: &'static str,

    // -- Tools page -------------------------------------------------------------
    pub tools_title: &'static str,
    pub tools_subtitle: &'static str,
    pub tools_sdio_desc: &'static str,
    pub tools_rapr_desc: &'static str,
    pub tools_nvclean_reco_desc: &'static str,
    pub tools_nvclean_open_desc: &'static str,
    pub tools_nvidia_auto: &'static str,
    pub tools_nvidia_auto_desc: &'static str,
    pub tools_winutil_desc: &'static str,

    // -- Top banner / window ------------------------------------------------
    pub app_heading: &'static str,
    pub root_prefix: &'static str,
    pub reboot_detected_prefix: &'static str,
    pub reboot_cbs: &'static str,
    pub reboot_windows_update: &'static str,
    pub reboot_pending_file_rename: &'static str,
    pub language_label: &'static str,
    pub language_en: &'static str,
    pub language_pt_br: &'static str,
    pub theme_label: &'static str,
    pub theme_system: &'static str,
    pub theme_light: &'static str,
    pub theme_dark: &'static str,
    pub text_size_label: &'static str,

    // -- Left panel -----------------------------------------------------
    pub categories_header: &'static str,
    pub cat_windows_update: &'static str,
    pub cat_store: &'static str,
    pub cat_apps: &'static str,
    pub cat_steam: &'static str,
    pub cat_drivers: &'static str,
    pub run_button: &'static str,
    pub running_button: &'static str,
    pub elapsed_prefix: &'static str,
    pub waiting_for_output: &'static str,
    pub tip_tools: &'static str,

    // -- Bottom status --------------------------------------------------
    pub status_running: &'static str,
    pub status_completed: &'static str,
    pub status_completed_with_issues: &'static str,
    pub status_idle: &'static str,
    pub status_engine_no_summary: &'static str,
    pub engine_not_found: &'static str,
    pub last_error_prefix: &'static str,

    // -- Tabs -------------------------------------------------------------
    pub tab_log: &'static str,
    pub tab_summary: &'static str,
    pub tab_tools: &'static str,
    pub tab_pins: &'static str,
    pub tab_driver_store: &'static str,

    // -- Summary tab ------------------------------------------------------
    pub summary_empty: &'static str,
    pub summary_row_store: &'static str,
    pub summary_row_steam: &'static str,
    pub summary_row_duration: &'static str,
    pub summary_row_log_file: &'static str,
    pub summary_exit_code_prefix: &'static str,
    pub summary_exit_stopped: &'static str,

    // -- Tools tab --------------------------------------------------------
    pub tools_group_drivers: &'static str,
    pub tools_open_sdio: &'static str,
    pub tools_open_rapr: &'static str,
    pub tools_nvclean_recommended: &'static str,
    pub tools_open_nvclean: &'static str,
    pub tools_group_system: &'static str,
    pub tools_open_winutil: &'static str,
    pub tools_group_app_install: &'static str,
    pub tools_no_presets: &'static str,
    pub tools_preset_label: &'static str,
    pub tools_preset_choose: &'static str,
    pub tools_install_apps_button: &'static str,

    // -- Bundle chooser dialog ------------------------------------------------
    pub bundle_dialog_title: &'static str,
    pub bundle_select_all: &'static str,
    pub bundle_select_none: &'static str,
    pub bundle_cancel: &'static str,
    pub bundle_load_failed_prefix: &'static str,

    // -- Progress -----------------------------------------------------------
    pub progress_phase_prefix: &'static str,

    // -- Pins tab -----------------------------------------------------------
    pub pins_intro: &'static str,
    pub pins_col_package_id: &'static str,
    pub pins_col_manager: &'static str,
    pub pins_delete: &'static str,
    pub pins_new_label: &'static str,
    pub pins_add: &'static str,
    pub pins_save: &'static str,
    pub pins_saved_msg: &'static str,
    pub pins_save_failed_prefix: &'static str,
    pub pins_detect_button: &'static str,
    pub pins_detect_loading: &'static str,
    pub pins_detect_hint: &'static str,

    // -- Startup & Services page ------------------------------------------------
    pub system_title: &'static str,
    pub system_subtitle: &'static str,
    pub tab_services: &'static str,
    pub tab_startup: &'static str,
    pub filter_label: &'static str,
    pub startup_col_enabled: &'static str,
    pub startup_on: &'static str,
    pub startup_off: &'static str,
    pub startup_once_label: &'static str,
    pub startup_once_hover: &'static str,
    pub startup_toggle_hover: &'static str,
    pub advice_col: &'static str,
    pub advice_keep: &'static str,
    pub advice_optional: &'static str,
    pub advice_safeoff: &'static str,
    pub sort_label: &'static str,
    pub sort_name: &'static str,
    pub sort_status: &'static str,
    pub sort_advice: &'static str,
    pub tab_tasks: &'static str,
    pub tasks_intro: &'static str,
    pub tasks_open_scheduler: &'static str,
    pub tasks_loading: &'static str,
    pub tasks_col_path: &'static str,
    pub time_col: &'static str,
    pub what_col: &'static str,
    pub system_export_button: &'static str,
    pub system_export_hover: &'static str,
    pub system_advanced_label: &'static str,
    pub system_advanced_hover: &'static str,
    pub services_intro: &'static str,
    pub services_open_console: &'static str,
    pub services_col_name: &'static str,
    pub services_col_display: &'static str,
    pub services_col_state: &'static str,
    pub services_col_start: &'static str,
    pub services_loading: &'static str,
    pub startup_intro: &'static str,
    pub startup_open_settings: &'static str,
    pub startup_col_name: &'static str,
    pub startup_col_location: &'static str,
    pub startup_col_command: &'static str,
    pub startup_loading: &'static str,
    pub drivers_intro: &'static str,

    // -- Driver store tab -----------------------------------------------------
    pub drivers_refresh: &'static str,
    pub drivers_querying: &'static str,
    pub drivers_col_published_name: &'static str,
    pub drivers_col_class: &'static str,
    pub drivers_col_version: &'static str,
    pub drivers_col_date: &'static str,
    pub drivers_query_timeout: &'static str,

    // -- Reboot dialog ------------------------------------------------------
    pub reboot_dialog_title: &'static str,
    pub reboot_dialog_body: &'static str,
    pub reboot_dialog_proceed: &'static str,
    pub reboot_dialog_cancel: &'static str,

    // -- NVCleanstall help dialog --------------------------------------------
    pub nvclean_help_title: &'static str,
    pub nvclean_help_intro: &'static str,
    pub nvclean_help_step1: &'static str,
    pub nvclean_help_step2: &'static str,
    pub nvclean_help_step3: &'static str,
    pub nvclean_help_step4: &'static str,
    pub nvclean_help_step5: &'static str,
    pub nvclean_help_step6: &'static str,
    pub nvclean_help_open_now: &'static str,

    // -- Toast ------------------------------------------------------------
    pub toast_title_ok: &'static str,
    pub toast_title_issues: &'static str,
    pub toast_cat_store: &'static str,
    pub toast_cat_apps: &'static str,
    pub toast_cat_steam: &'static str,

    // -- Status chip labels -------------------------------------------------
    pub status_chip_idle: &'static str,
    pub status_chip_running: &'static str,
    pub status_chip_ok: &'static str,
    pub status_chip_error: &'static str,
    pub status_chip_skipped: &'static str,
}

pub static EN: Strings = Strings {
    tagline: "Keep your PC updated and set up new ones \u{2014} in a few clicks.",
    nav_update: "\u{1F504} Update",
    nav_install: "\u{1F4E6} Install Apps",
    nav_newpc: "\u{1F5A5} New PC",
    nav_optimize: "\u{1F680} Optimize",
    nav_system: "\u{1F6A6} Startup",
    nav_tools: "\u{1F527} Tools",
    nav_advanced: "\u{2699} Advanced",

    update_title: "Keep your PC up to date",
    update_subtitle: "Pick what to update and press the big green button. Everything runs by itself \u{2014} you can minimize this window and you'll get a notification when it's done.",
    cat_windows_update_desc: "Security patches and fixes from Microsoft",
    cat_store_desc: "Apps installed from the Microsoft Store",
    cat_apps_desc: "Updates all your installed programs at once. winget, chocolatey and topgrade are 'package managers' \u{2014} helpers that fetch each program's update straight from its maker.",
    cat_steam_desc: "Checks your installed games and downloads their updates (Steam library for now)",
    run_cta: "Update everything now",
    stop_cta: "Stop this run",
    stopping_button: "Stopping...",
    view_full_log: "View full log",
    result_ok_title: "\u{2714} All done \u{2014} everything is up to date",
    result_issues_title: "\u{26A0} Finished, but some items had issues",
    result_no_summary_title: "\u{26A0} The update stopped unexpectedly",

    install_title: "Install apps",
    install_subtitle: "Tick any apps you want and press Install \u{2014} or pick a starter pack to pre-select a good set.",
    install_step2_hint: "Review the list below, untick anything you don't want, then press Install.",
    install_console_note: "A window will open showing installation progress. Already-installed apps are skipped automatically.",
    pack_basic_name: "Essentials",
    pack_basic_desc: "The basics for any PC: browser, video player, PDF reader, archiver and more.",
    pack_dev_name: "Developer setup",
    pack_dev_desc: "Git, editors, languages and tools for a development machine.",
    pack_full_name: "Everything",
    pack_full_desc: "The complete catalog \u{2014} pick and choose from all available apps.",
    pack_generic_desc: "A custom app pack.",
    pack_apps_suffix: "apps",

    setup_title: "Set up a new PC",
    setup_subtitle: "For a freshly installed Windows. Tick the steps you want and press the button \u{2014} a window opens showing progress, Windows asks for permission once (UAC), and a restart at the end is recommended.",
    setup_run_cta: "Set up this PC now",
    setup_console_note: "A PowerShell window will open showing progress. You can keep using the PC meanwhile.",
    setup_details_header: "Review & choose each change",
    setup_restore_title: "Safety net (restore point)",
    setup_restore_desc: "Creates a System Restore point first, so everything below can be undone from Windows recovery.",
    setup_tweaks_title: "Privacy & cleanup tweaks",
    setup_tweaks_desc: "Applies the recommended Windows tweaks and removes pre-installed junk apps. Open the list below to pick them one by one (shared with the Optimize page).",
    setup_toggles_title: "Nice defaults",
    setup_toggles_desc: "Dark theme, visible file extensions, mouse acceleration off, Num Lock on at startup and more. Open the list below to pick them one by one.",
    setup_drivers_title: "Drivers",
    setup_drivers_desc: "SDIO finds and installs missing drivers automatically (it may download driver packs first \u{2014} can take a while). With an NVIDIA card and a prepared NVCleanstall package, that is used for the graphics driver: clean install, no telemetry, no restart.",
    setup_oosu_title: "O&O ShutUp10++ (privacy)",
    setup_oosu_desc: "A well-known free privacy tool that turns off dozens of Windows data-collection switches in one go. Automatic applies O&O's own 'Recommended' settings silently; Manual opens the program so you pick yourself.",
    setup_apps_title: "Essential apps",
    setup_apps_desc: "Installs the Essentials pack: browser, video player, PDF reader, archiver and more. Pick different apps on the Install Apps page instead if you prefer.",

    optimize_title: "Optimize Windows",
    optimize_subtitle: "Recommended tweaks, each explained in plain language. A restore point is created first, so everything can be undone. Items marked \u{26A0} have a real trade-off \u{2014} read them before applying.",
    optimize_group_tweaks: "Windows tweaks",
    optimize_group_toggles: "Preferences",
    optimize_caution_badge: "\u{26A0} trade-off",
    optimize_apply_cta: "Apply selected optimizations",
    optimize_reset_button: "Reset to recommended",
    optimize_oosu_include: "Also run O&O ShutUp10++",
    optimize_oosu_desc: "A well-known free privacy tool that turns off dozens of Windows data-collection switches in one go. Automatic applies O&O's own 'Recommended' settings silently; Manual opens the program so you pick yourself.",
    oosu_mode_auto: "Automatic \u{2014} recommended settings, no clicks needed",
    oosu_mode_manual: "Manual \u{2014} opens the program for you to choose",

    tools_title: "Tools",
    tools_subtitle: "Extra utilities for drivers and system maintenance. Each opens in its own window.",
    tools_sdio_desc: "Finds and installs missing or newer device drivers. Review its suggestions before installing.",
    tools_rapr_desc: "View and clean up old drivers stored by Windows.",
    tools_nvclean_reco_desc: "Installs your prepared NVIDIA driver package silently (no telemetry, no restart).",
    tools_nvclean_open_desc: "Open NVCleanstall to customize a driver installation (downloads the portable version automatically the first time).",
    tools_nvidia_auto: "NVIDIA driver \u{2014} automatic clean update",
    tools_nvidia_auto_desc: "Fully automatic: fetches the newest driver from NVIDIA, keeps only the driver + audio (no GeForce Experience, no telemetry) and installs it silently.",
    tools_winutil_desc: "Chris Titus' Windows toolbox: tweaks, debloat and more (opens a PowerShell window).",

    app_heading: "Upkeep",
    root_prefix: "root:",
    reboot_detected_prefix: "\u{26A0} Pending reboot detected:",
    reboot_cbs: "CBS",
    reboot_windows_update: "Windows Update",
    reboot_pending_file_rename: "PendingFileRename",
    language_label: "Language / Idioma",
    language_en: "English",
    language_pt_br: "Portugu\u{ea}s (BR)",

    theme_label: "Theme",
    theme_system: "System",
    theme_light: "Light",
    theme_dark: "Dark",
    text_size_label: "Text size",

    categories_header: "Categories",
    cat_windows_update: "Windows Update",
    cat_store: "Microsoft Store",
    cat_apps: "Programs (winget \u{b7} choco \u{b7} topgrade)",
    cat_steam: "Games (Steam)",
    cat_drivers: "Drivers",
    run_button: "Run",
    running_button: "Running...",
    elapsed_prefix: "Elapsed:",
    waiting_for_output: "Waiting for output...",
    tip_tools: "Tip: see the Tools tab for driver utilities, winutil and app-preset installs.",

    status_running: "Running",
    status_completed: "Completed",
    status_completed_with_issues: "Completed with issues",
    status_idle: "Idle",
    status_engine_no_summary: "Engine stopped unexpectedly (no summary received)",
    engine_not_found: "engine not found",
    last_error_prefix: "Last error:",

    tab_log: "Log",
    tab_summary: "Summary",
    tab_tools: "Tools",
    tab_pins: "Pins",
    tab_driver_store: "Driver Store",

    summary_empty: "No summary yet \u{2014} run a category first.",
    summary_row_store: "Store",
    summary_row_steam: "Steam games",
    summary_row_duration: "Duration",
    summary_row_log_file: "Log file",
    summary_exit_code_prefix: "Engine exit code:",
    summary_exit_stopped: "stopped by the dashboard after the run finished (expected)",

    tools_group_drivers: "Drivers",
    tools_open_sdio: "Open SDIO",
    tools_open_rapr: "Driver Store Explorer (RAPR)",
    tools_nvclean_recommended: "NVCleanstall \u{2014} Recommended Update",
    tools_open_nvclean: "Open NVCleanstall",
    tools_group_system: "System",
    tools_open_winutil: "Open winutil",
    tools_group_app_install: "App install",
    tools_no_presets: "No presets found under <root>/presets/*.json",
    tools_preset_label: "Preset",
    tools_preset_choose: "(choose)",
    tools_install_apps_button: "View & install apps...",

    bundle_dialog_title: "Choose apps to install",
    bundle_select_all: "Select all",
    bundle_select_none: "Clear selection",
    bundle_cancel: "Cancel",
    bundle_load_failed_prefix: "Could not load app bundle:",

    progress_phase_prefix: "Phase:",

    pins_intro: "Pinned packages are excluded from winget/choco updates.",
    pins_col_package_id: "Package ID",
    pins_col_manager: "Manager",
    pins_delete: "Delete",
    pins_new_label: "New pin:",
    pins_add: "Add",
    pins_save: "Save Pins",
    pins_saved_msg: "Pins saved.",
    pins_save_failed_prefix: "Save failed:",
    pins_detect_button: "Detect installed apps",
    pins_detect_loading: "Detecting installed apps (winget + choco)...",
    pins_detect_hint: "Or pick from what's installed instead of typing:",

    system_title: "Startup & Services",
    system_subtitle: "What runs automatically on your PC \u{2014} and the switch to turn each thing off. Hover any item for an explanation of what it is.",
    tab_services: "Services",
    tab_startup: "Startup apps",
    filter_label: "Filter:",
    startup_col_enabled: "On/Off",
    startup_on: "On",
    startup_off: "Off",
    startup_once_label: "one-time",
    startup_once_hover: "A RunOnce entry: it runs a single time on the next sign-in and removes itself. Nothing to toggle.",
    startup_toggle_hover: "Same switch as Task Manager's Startup tab \u{2014} nothing is deleted, and you can turn it back on any time.",
    advice_col: "Advice",
    advice_keep: "keep",
    advice_optional: "your choice",
    advice_safeoff: "safe to turn off",
    sort_label: "Sort:",
    sort_name: "Name",
    sort_status: "On/Off",
    sort_advice: "Advice",
    tab_tasks: "Scheduled tasks",
    tasks_intro: "Scheduled tasks that fire at boot or sign-in \u{2014} mostly updaters and helpers apps register for themselves. The switch uses Windows' own enable/disable for tasks; nothing is deleted.",
    tasks_open_scheduler: "Open Task Scheduler",
    tasks_loading: "Reading scheduled tasks...",
    tasks_col_path: "Folder",
    time_col: "Time",
    what_col: "What it does",
    system_export_button: "\u{1F4C4} Export report (.md)",
    system_export_hover: "Writes StartupReport.md with every startup program, scheduled task and service \u{2014} including the file each one launches \u{2014} so you can research items one by one.",
    system_advanced_label: "Advanced",
    system_advanced_hover: "Also show the items best left alone: everything marked 'keep', and (for services) the ones this tool doesn't recognize \u{2014} mostly core Windows components.",
    services_intro: "Background services Windows runs. Hover a service to read Windows' own description of what it does. The start-type menu changes how it launches \u{2014} 'Disabled' stops it completely, so only disable things you recognize.",
    services_open_console: "Open Services console",
    services_col_name: "Service",
    services_col_display: "Name",
    services_col_state: "Status",
    services_col_start: "Start type",
    services_loading: "Reading services...",
    startup_intro: "Programs that launch automatically with Windows. Use the On/Off switch to stop one \u{2014} it uses the same mechanism as Task Manager, deletes nothing, and is reversible. Hover a name to see where it comes from.",
    startup_open_settings: "Open Startup settings",
    startup_col_name: "Name",
    startup_col_location: "Location",
    startup_col_command: "Command",
    startup_loading: "Reading startup entries...",
    drivers_intro: "Windows keeps every driver version ever installed in its 'driver store' \u{2014} old versions (GPU drivers especially) can waste gigabytes. This lists them; to clean up safely use Driver Store Explorer on the Tools page.",

    drivers_refresh: "Refresh",
    drivers_querying: "Querying driver store...",
    drivers_col_published_name: "Published Name",
    drivers_col_class: "Class",
    drivers_col_version: "Version",
    drivers_col_date: "Date",
    drivers_query_timeout: "Driver store query timed out.",

    reboot_dialog_title: "Pending Reboot Warning",
    reboot_dialog_body:
        "A pending reboot has been detected. Running updates in this state may cause issues.",
    reboot_dialog_proceed: "Proceed anyway",
    reboot_dialog_cancel: "Cancel",

    nvclean_help_title: "NVCleanstall \u{2014} one-time setup needed",
    nvclean_help_intro: "NVCleanstall has no CLI for driver selection. To enable unattended runs:",
    nvclean_help_step1: "1. Open NVCleanstall once.",
    nvclean_help_step2: "2. Choose the \"Recommended\" preset.",
    nvclean_help_step3: "3. Enable \"Disable Installer Telemetry & Advertising\".",
    nvclean_help_step4: "4. Enable \"Unattended Express Installation\".",
    nvclean_help_step5: "5. Use \"Build Package\" to create a standalone installer exe.",
    nvclean_help_step6: "6. Save that exe's path into settings.json as NVCleanPackagePath.",
    nvclean_help_open_now: "Open NVCleanstall now",

    toast_title_ok: "Upkeep finished successfully",
    toast_title_issues: "Upkeep finished with issues",
    toast_cat_store: "Store",
    toast_cat_apps: "Apps",
    toast_cat_steam: "Steam",

    status_chip_idle: "idle",
    status_chip_running: "running",
    status_chip_ok: "ok",
    status_chip_error: "error",
    status_chip_skipped: "skipped",
};

pub static PT_BR: Strings = Strings {
    tagline: "Mantenha seu PC atualizado e configure PCs novos \u{2014} em poucos cliques.",
    nav_update: "\u{1F504} Atualizar",
    nav_install: "\u{1F4E6} Instalar Apps",
    nav_newpc: "\u{1F5A5} PC Novo",
    nav_optimize: "\u{1F680} Otimizar",
    nav_system: "\u{1F6A6} Inicializa\u{e7}\u{e3}o",
    nav_tools: "\u{1F527} Ferramentas",
    nav_advanced: "\u{2699} Avan\u{e7}ado",

    update_title: "Mantenha seu PC em dia",
    update_subtitle: "Escolha o que atualizar e aperte o bot\u{e3}o verde. Tudo roda sozinho \u{2014} voc\u{ea} pode minimizar esta janela e receber\u{e1} uma notifica\u{e7}\u{e3}o ao terminar.",
    cat_windows_update_desc: "Corre\u{e7}\u{f5}es e patches de seguran\u{e7}a da Microsoft",
    cat_store_desc: "Aplicativos instalados pela Loja Microsoft",
    cat_apps_desc: "Atualiza todos os seus programas de uma vez. winget, chocolatey e topgrade s\u{e3}o 'gerenciadores de pacotes' \u{2014} assistentes que baixam a atualiza\u{e7}\u{e3}o de cada programa direto do fabricante.",
    cat_steam_desc: "Procura atualiza\u{e7}\u{f5}es dos seus jogos instalados e as baixa (por enquanto, a biblioteca Steam)",
    run_cta: "Atualizar tudo agora",
    stop_cta: "Parar esta execu\u{e7}\u{e3}o",
    stopping_button: "Parando...",
    view_full_log: "Ver log completo",
    result_ok_title: "\u{2714} Tudo pronto \u{2014} seu PC est\u{e1} atualizado",
    result_issues_title: "\u{26A0} Conclu\u{ed}do, mas alguns itens tiveram problemas",
    result_no_summary_title: "\u{26A0} A atualiza\u{e7}\u{e3}o parou inesperadamente",

    install_title: "Instalar aplicativos",
    install_subtitle: "Marque os apps que quiser e aperte Instalar \u{2014} ou escolha um pacote inicial para pr\u{e9}-selecionar um bom conjunto.",
    install_step2_hint: "Revise a lista abaixo, desmarque o que n\u{e3}o quiser e aperte Instalar.",
    install_console_note: "Uma janela vai abrir mostrando o progresso. Apps j\u{e1} instalados s\u{e3}o pulados automaticamente.",
    pack_basic_name: "Essenciais",
    pack_basic_desc: "O b\u{e1}sico para qualquer PC: navegador, player de v\u{ed}deo, leitor de PDF, compactador e mais.",
    pack_dev_name: "Setup de desenvolvedor",
    pack_dev_desc: "Git, editores, linguagens e ferramentas para uma m\u{e1}quina de desenvolvimento.",
    pack_full_name: "Tudo",
    pack_full_desc: "O cat\u{e1}logo completo \u{2014} escolha entre todos os apps dispon\u{ed}veis.",
    pack_generic_desc: "Um pacote de apps personalizado.",
    pack_apps_suffix: "apps",

    setup_title: "Configurar um PC novo",
    setup_subtitle: "Para um Windows rec\u{e9}m-instalado. Marque as etapas desejadas e aperte o bot\u{e3}o \u{2014} uma janela mostra o progresso, o Windows pede permiss\u{e3}o uma vez (UAC) e, ao final, \u{e9} recomendado reiniciar o PC.",
    setup_run_cta: "Configurar este PC agora",
    setup_console_note: "Uma janela do PowerShell vai abrir mostrando o progresso. Voc\u{ea} pode continuar usando o PC normalmente enquanto isso.",
    setup_details_header: "Ver e escolher cada mudan\u{e7}a",
    setup_restore_title: "Ponto de restaura\u{e7}\u{e3}o (rede de seguran\u{e7}a)",
    setup_restore_desc: "Antes de qualquer mudan\u{e7}a, cria um ponto de Restaura\u{e7}\u{e3}o do Sistema \u{2014} se algo der errado, d\u{e1} para voltar atr\u{e1}s pela recupera\u{e7}\u{e3}o do Windows.",
    setup_tweaks_title: "Privacidade e limpeza",
    setup_tweaks_desc: "Aplica os ajustes recomendados do Windows e remove apps pr\u{e9}-instalados in\u{fa}teis. Abra a lista abaixo para escolher item por item (a sele\u{e7}\u{e3}o \u{e9} a mesma da p\u{e1}gina Otimizar).",
    setup_toggles_title: "Prefer\u{ea}ncias recomendadas",
    setup_toggles_desc: "Tema escuro, extens\u{f5}es de arquivo vis\u{ed}veis, acelera\u{e7}\u{e3}o do mouse desligada, Num Lock ativado ao iniciar e mais. Abra a lista abaixo para escolher item por item.",
    setup_drivers_title: "Drivers",
    setup_drivers_desc: "O SDIO encontra e instala automaticamente os drivers que faltam (antes disso, pode baixar pacotes de drivers \u{2014} isso pode demorar). Se houver placa NVIDIA e um pacote do NVCleanstall preparado, ele \u{e9} usado para o driver de v\u{ed}deo: instala\u{e7}\u{e3}o limpa, sem telemetria e sem reiniciar.",
    setup_oosu_title: "O&O ShutUp10++ (privacidade)",
    setup_oosu_desc: "Ferramenta de privacidade gratuita e conhecida que desliga dezenas de op\u{e7}\u{f5}es de coleta de dados do Windows de uma vez. No autom\u{e1}tico, as configura\u{e7}\u{f5}es 'recomendadas' da pr\u{f3}pria O&O s\u{e3}o aplicadas em sil\u{ea}ncio; no manual, o programa abre para voc\u{ea} escolher.",
    setup_apps_title: "Apps essenciais",
    setup_apps_desc: "Instala o pacote Essenciais: navegador, player de v\u{ed}deo, leitor de PDF, compactador e mais. Prefere outros apps? Escolha na p\u{e1}gina Instalar Apps.",

    optimize_title: "Otimizar o Windows",
    optimize_subtitle: "Ajustes recomendados, cada um explicado em linguagem simples. Um ponto de restaura\u{e7}\u{e3}o \u{e9} criado antes de tudo, ent\u{e3}o d\u{e1} para desfazer qualquer coisa. Itens marcados com \u{26A0} t\u{ea}m um efeito colateral real \u{2014} leia antes de aplicar.",
    optimize_group_tweaks: "Ajustes do Windows",
    optimize_group_toggles: "Prefer\u{ea}ncias",
    optimize_caution_badge: "\u{26A0} efeito colateral",
    optimize_apply_cta: "Aplicar as otimiza\u{e7}\u{f5}es selecionadas",
    optimize_reset_button: "Restaurar recomendados",
    optimize_oosu_include: "Rodar tamb\u{e9}m o O&O ShutUp10++",
    optimize_oosu_desc: "Ferramenta de privacidade gratuita e conhecida que desliga dezenas de op\u{e7}\u{f5}es de coleta de dados do Windows de uma vez. No autom\u{e1}tico, as configura\u{e7}\u{f5}es 'recomendadas' da pr\u{f3}pria O&O s\u{e3}o aplicadas em sil\u{ea}ncio; no manual, o programa abre para voc\u{ea} escolher.",
    oosu_mode_auto: "Autom\u{e1}tico \u{2014} configura\u{e7}\u{f5}es recomendadas, sem cliques",
    oosu_mode_manual: "Manual \u{2014} abre o programa para voc\u{ea} escolher",

    tools_title: "Ferramentas",
    tools_subtitle: "Utilit\u{e1}rios extras para drivers e manuten\u{e7}\u{e3}o. Cada um abre em sua pr\u{f3}pria janela.",
    tools_sdio_desc: "Encontra e instala drivers que faltam ou que t\u{ea}m vers\u{e3}o mais nova. Revise as sugest\u{f5}es antes de instalar.",
    tools_rapr_desc: "Veja e limpe drivers antigos guardados pelo Windows.",
    tools_nvclean_reco_desc: "Instala em sil\u{ea}ncio o pacote de driver NVIDIA que voc\u{ea} preparou (sem telemetria e sem reiniciar).",
    tools_nvclean_open_desc: "Abre o NVCleanstall para personalizar a instala\u{e7}\u{e3}o do driver (baixa a vers\u{e3}o port\u{e1}til automaticamente na primeira vez).",
    tools_nvidia_auto: "Driver NVIDIA \u{2014} atualiza\u{e7}\u{e3}o limpa autom\u{e1}tica",
    tools_nvidia_auto_desc: "Totalmente autom\u{e1}tico: baixa o driver mais novo da NVIDIA, mant\u{e9}m s\u{f3} o driver + \u{e1}udio (sem GeForce Experience, sem telemetria) e instala em sil\u{ea}ncio.",
    tools_winutil_desc: "Caixa de ferramentas do Chris Titus: ajustes, limpeza e mais (abre uma janela do PowerShell).",

    app_heading: "Upkeep",
    root_prefix: "raiz:",
    reboot_detected_prefix: "\u{26A0} Reinicializa\u{e7}\u{e3}o pendente detectada:",
    reboot_cbs: "CBS",
    reboot_windows_update: "Windows Update",
    reboot_pending_file_rename: "PendingFileRename",
    language_label: "Language / Idioma",
    language_en: "English",
    language_pt_br: "Portugu\u{ea}s (BR)",

    theme_label: "Tema",
    theme_system: "Do sistema",
    theme_light: "Claro",
    theme_dark: "Escuro",
    text_size_label: "Tamanho do texto",

    categories_header: "Categorias",
    cat_windows_update: "Windows Update",
    cat_store: "Loja Microsoft",
    cat_apps: "Programas (winget \u{b7} choco \u{b7} topgrade)",
    cat_steam: "Jogos (Steam)",
    cat_drivers: "Drivers",
    run_button: "Executar",
    running_button: "Executando...",
    elapsed_prefix: "Decorrido:",
    waiting_for_output: "Aguardando sa\u{ed}da...",
    tip_tools:
        "Dica: veja a aba Ferramentas para utilit\u{e1}rios de drivers, winutil e instala\u{e7}\u{e3}o de predefini\u{e7}\u{f5}es de apps.",

    status_running: "Executando",
    status_completed: "Conclu\u{ed}do",
    status_completed_with_issues: "Conclu\u{ed}do com problemas",
    status_idle: "Ocioso",
    status_engine_no_summary: "O motor parou inesperadamente (nenhum resumo recebido)",
    engine_not_found: "motor n\u{e3}o encontrado",
    last_error_prefix: "\u{da}ltimo erro:",

    tab_log: "Log",
    tab_summary: "Resumo",
    tab_tools: "Ferramentas",
    tab_pins: "Pins",
    tab_driver_store: "Reposit\u{f3}rio de Drivers",

    summary_empty: "Nenhum resumo ainda \u{2014} execute uma categoria primeiro.",
    summary_row_store: "Loja",
    summary_row_steam: "Jogos Steam",
    summary_row_duration: "Dura\u{e7}\u{e3}o",
    summary_row_log_file: "Arquivo de log",
    summary_exit_code_prefix: "C\u{f3}digo de sa\u{ed}da do motor:",
    summary_exit_stopped: "encerrado pelo painel ap\u{f3}s o t\u{e9}rmino (esperado)",

    tools_group_drivers: "Drivers",
    tools_open_sdio: "Abrir SDIO",
    tools_open_rapr: "Explorador de Reposit\u{f3}rio de Drivers (RAPR)",
    tools_nvclean_recommended: "NVCleanstall \u{2014} Atualiza\u{e7}\u{e3}o Recomendada",
    tools_open_nvclean: "Abrir NVCleanstall",
    tools_group_system: "Sistema",
    tools_open_winutil: "Abrir winutil",
    tools_group_app_install: "Instala\u{e7}\u{e3}o de apps",
    tools_no_presets: "Nenhuma predefini\u{e7}\u{e3}o encontrada em <root>/presets/*.json",
    tools_preset_label: "Predefini\u{e7}\u{e3}o",
    tools_preset_choose: "(escolher)",
    tools_install_apps_button: "Ver e instalar apps...",

    bundle_dialog_title: "Escolha os apps para instalar",
    bundle_select_all: "Selecionar todos",
    bundle_select_none: "Limpar sele\u{e7}\u{e3}o",
    bundle_cancel: "Cancelar",
    bundle_load_failed_prefix: "N\u{e3}o foi poss\u{ed}vel carregar o pacote de apps:",

    progress_phase_prefix: "Fase:",

    pins_intro: "Os pacotes fixados s\u{e3}o exclu\u{ed}dos das atualiza\u{e7}\u{f5}es do winget/choco.",
    pins_col_package_id: "ID do Pacote",
    pins_col_manager: "Gerenciador",
    pins_delete: "Excluir",
    pins_new_label: "Novo pin:",
    pins_add: "Adicionar",
    pins_save: "Salvar Pins",
    pins_saved_msg: "Pins salvos.",
    pins_save_failed_prefix: "Falha ao salvar:",
    pins_detect_button: "Detectar apps instalados",
    pins_detect_loading: "Detectando apps instalados (winget + choco)...",
    pins_detect_hint: "Ou escolha entre os instalados em vez de digitar:",

    system_title: "Inicializa\u{e7}\u{e3}o e Servi\u{e7}os",
    system_subtitle: "O que roda automaticamente no seu PC \u{2014} e o interruptor para desligar cada item. Passe o mouse sobre um item para ver a explica\u{e7}\u{e3}o do que ele \u{e9}.",
    tab_services: "Servi\u{e7}os",
    tab_startup: "Apps de inicializa\u{e7}\u{e3}o",
    filter_label: "Filtrar:",
    startup_col_enabled: "Liga/Desliga",
    startup_on: "Ligado",
    startup_off: "Desligado",
    startup_once_label: "uma vez",
    startup_once_hover: "Entrada RunOnce: roda uma \u{fa}nica vez no pr\u{f3}ximo login e se remove sozinha. N\u{e3}o h\u{e1} o que desligar.",
    startup_toggle_hover: "Mesmo interruptor da aba Inicializar do Gerenciador de Tarefas \u{2014} nada \u{e9} apagado e d\u{e1} para religar quando quiser.",
    advice_col: "Recomenda\u{e7}\u{e3}o",
    advice_keep: "manter",
    advice_optional: "sua escolha",
    advice_safeoff: "pode desligar",
    sort_label: "Ordenar:",
    sort_name: "Nome",
    sort_status: "Liga/Desliga",
    sort_advice: "Recomenda\u{e7}\u{e3}o",
    tab_tasks: "Tarefas agendadas",
    tasks_intro: "Tarefas agendadas que disparam no boot ou no login \u{2014} em geral atualizadores e auxiliares que os pr\u{f3}prios apps registram. O interruptor usa o ativar/desativar do pr\u{f3}prio Windows; nada \u{e9} apagado.",
    tasks_open_scheduler: "Abrir Agendador de Tarefas",
    tasks_loading: "Lendo tarefas agendadas...",
    tasks_col_path: "Pasta",
    time_col: "Tempo",
    what_col: "O que faz",
    system_export_button: "\u{1F4C4} Exportar relat\u{f3}rio (.md)",
    system_export_hover: "Gera o StartupReport.md com todos os programas de inicializa\u{e7}\u{e3}o, tarefas agendadas e servi\u{e7}os \u{2014} incluindo o arquivo que cada um executa \u{2014} para voc\u{ea} pesquisar item por item.",
    system_advanced_label: "Avan\u{e7}ado",
    system_advanced_hover: "Mostra tamb\u{e9}m os itens que \u{e9} melhor n\u{e3}o mexer: tudo marcado como 'manter' e (nos servi\u{e7}os) os que a ferramenta n\u{e3}o reconhece \u{2014} em geral componentes essenciais do Windows.",
    services_intro: "Servi\u{e7}os que o Windows executa em segundo plano. Passe o mouse sobre um servi\u{e7}o para ler a descri\u{e7}\u{e3}o do pr\u{f3}prio Windows. O menu de tipo de in\u{ed}cio muda como ele inicia \u{2014} 'Disabled' para o servi\u{e7}o por completo, ent\u{e3}o desative s\u{f3} o que voc\u{ea} reconhece.",
    services_open_console: "Abrir console de Servi\u{e7}os",
    services_col_name: "Servi\u{e7}o",
    services_col_display: "Nome",
    services_col_state: "Status",
    services_col_start: "Tipo de in\u{ed}cio",
    services_loading: "Lendo servi\u{e7}os...",
    startup_intro: "Programas que iniciam automaticamente com o Windows. Use o interruptor Liga/Desliga para impedir um deles \u{2014} \u{e9} o mesmo mecanismo do Gerenciador de Tarefas, nada \u{e9} apagado e d\u{e1} para reverter. Passe o mouse sobre o nome para ver de onde ele vem.",
    startup_open_settings: "Abrir configura\u{e7}\u{f5}es de Inicializa\u{e7}\u{e3}o",
    startup_col_name: "Nome",
    startup_col_location: "Local",
    startup_col_command: "Comando",
    startup_loading: "Lendo itens de inicializa\u{e7}\u{e3}o...",
    drivers_intro: "O Windows guarda todas as vers\u{f5}es de driver j\u{e1} instaladas no 'reposit\u{f3}rio de drivers' \u{2014} vers\u{f5}es antigas (principalmente de v\u{ed}deo) podem desperdi\u{e7}ar gigabytes. Esta lista mostra todas; para limpar com seguran\u{e7}a, use o Driver Store Explorer na p\u{e1}gina Ferramentas.",

    drivers_refresh: "Atualizar",
    drivers_querying: "Consultando reposit\u{f3}rio de drivers...",
    drivers_col_published_name: "Nome Publicado",
    drivers_col_class: "Classe",
    drivers_col_version: "Vers\u{e3}o",
    drivers_col_date: "Data",
    drivers_query_timeout: "A consulta ao reposit\u{f3}rio de drivers expirou.",

    reboot_dialog_title: "Aviso de Reinicializa\u{e7}\u{e3}o Pendente",
    reboot_dialog_body:
        "Foi detectada uma reinicializa\u{e7}\u{e3}o pendente. Executar atualiza\u{e7}\u{f5}es nesse estado pode causar problemas.",
    reboot_dialog_proceed: "Continuar mesmo assim",
    reboot_dialog_cancel: "Cancelar",

    nvclean_help_title: "NVCleanstall \u{2014} configura\u{e7}\u{e3}o \u{fa}nica necess\u{e1}ria",
    nvclean_help_intro:
        "O NVCleanstall n\u{e3}o possui CLI para sele\u{e7}\u{e3}o de drivers. Para permitir execu\u{e7}\u{f5}es n\u{e3}o assistidas:",
    nvclean_help_step1: "1. Abra o NVCleanstall uma vez.",
    nvclean_help_step2: "2. Escolha a predefini\u{e7}\u{e3}o \"Recommended\".",
    nvclean_help_step3: "3. Ative \"Disable Installer Telemetry & Advertising\".",
    nvclean_help_step4: "4. Ative \"Unattended Express Installation\".",
    nvclean_help_step5:
        "5. Use \"Build Package\" para criar um instalador standalone (exe).",
    nvclean_help_step6:
        "6. Salve o caminho desse exe em settings.json como NVCleanPackagePath.",
    nvclean_help_open_now: "Abrir NVCleanstall agora",

    toast_title_ok: "Upkeep conclu\u{ed}do com sucesso",
    toast_title_issues: "Upkeep conclu\u{ed}do com problemas",
    toast_cat_store: "Loja",
    toast_cat_apps: "Aplicativos",
    toast_cat_steam: "Steam",

    status_chip_idle: "ocioso",
    status_chip_running: "executando",
    status_chip_ok: "ok",
    status_chip_error: "erro",
    status_chip_skipped: "ignorado",
};

/// Returns the translation table for `lang`.
pub fn tr(lang: Lang) -> &'static Strings {
    match lang {
        Lang::En => &EN,
        Lang::PtBr => &PT_BR,
    }
}

/// Localized "engine .bat not found at startup" message. Kept as a function
/// (rather than a `Strings` field) since `bat_name` is interpolated mid
/// sentence and word order differs between languages.
pub fn startup_error(lang: Lang, bat_name: &str) -> String {
    match lang {
        Lang::En => format!(
            "Could not locate {bat_name} \u{2014} searched upward from the executable's folder and the current directory. Running the engine is disabled until this is resolved."
        ),
        Lang::PtBr => format!(
            "N\u{e3}o foi poss\u{ed}vel localizar {bat_name} \u{2014} busca realizada a partir da pasta do execut\u{e1}vel e do diret\u{f3}rio atual, subindo os n\u{ed}veis. A execu\u{e7}\u{e3}o do motor est\u{e1} desabilitada at\u{e9} que isso seja resolvido."
        ),
    }
}

/// Localized "Failed (exit code N)" bottom-status label.
pub fn status_failed(lang: Lang, code: i32) -> String {
    match lang {
        Lang::En => format!("Failed (exit code {code})"),
        Lang::PtBr => format!("Falha (c\u{f3}digo de sa\u{ed}da {code})"),
    }
}

/// Localized "pnputil failed with exit code N" driver-store error. `None`
/// means the process exited without the OS reporting a code.
pub fn pnputil_failed(lang: Lang, code: Option<i32>) -> String {
    match (lang, code) {
        (Lang::En, Some(code)) => format!("pnputil failed with exit code {code}"),
        (Lang::En, None) => "pnputil failed (no exit code reported)".to_string(),
        (Lang::PtBr, Some(code)) => {
            format!("pnputil falhou com c\u{f3}digo de sa\u{ed}da {code}")
        }
        (Lang::PtBr, None) => {
            "pnputil falhou (nenhum c\u{f3}digo de sa\u{ed}da reportado)".to_string()
        }
    }
}

/// Localized "Install N selected" bundle-dialog button label.
pub fn bundle_install_selected(lang: Lang, n: usize) -> String {
    match lang {
        Lang::En => format!("Install {n} selected"),
        Lang::PtBr => format!("Instalar {n} selecionados"),
    }
}

/// Plain-language (title, why) for an optimization tweak slug from
/// `crate::optimize::TWEAKS`. Unknown slugs fall back to the slug itself.
pub fn tweak_text(lang: Lang, slug: &str) -> (&'static str, &'static str) {
    match lang {
        Lang::En => match slug {
            "telemetry" => ("Telemetry off", "Stops Windows sending usage and diagnostic data to Microsoft."),
            "activity" => ("Activity history off", "Stops Windows keeping a timeline of everything you open and do."),
            "consumer-features" => ("No auto-installed suggestions", "Stops Windows silently installing suggested apps and games from the Store."),
            "debloat-apps" => ("Remove pre-installed junk apps", "Uninstalls promo apps (Feedback Hub, Office promo, Solitaire, Bing News, Copilot...). Keeps useful ones like Calculator, Photos, Weather and Sticky Notes."),
            "store-search" => ("No Store ads in search", "Start menu search stops suggesting Microsoft Store apps you don't have."),
            "windows-ai" => ("Remove Windows AI / Copilot", "Removes Copilot, Recall and other built-in AI features. Hard to undo later."),
            "edge-debloat" => ("Calm down Microsoft Edge", "Disables Edge's popups, ads and telemetry. The browser stays installed."),
            "brave-debloat" => ("Trim Brave extras", "Turns off Brave Rewards, crypto wallet, VPN offers and the Leo AI. Only matters if Brave is installed."),
            "delivery-optimization" => ("Don't share updates with strangers", "Stops your internet connection being used to upload Windows updates to other people's PCs."),
            "services-manual" => ("Fewer background services", "Sets many Windows services to start only when needed, freeing memory."),
            "end-task" => ("Right-click closes frozen apps", "Adds an 'End task' option when you right-click an app icon in the taskbar."),
            "explorer-discovery" => ("Faster folders", "Stops Windows analyzing folder contents to guess a layout, so folders open instantly."),
            "disk-cleanup" => ("Disk cleanup", "Runs Windows Disk Cleanup once to free space taken by old files."),
            "temp-files" => ("Remove temporary files", "Deletes leftover temporary files that only take up space."),
            "wpbt" => ("Block manufacturer bloat (WPBT)", "Stops the PC maker's firmware from auto-installing its own software into Windows."),
            "adobe-block" => ("Block Adobe telemetry servers", "Blocks Adobe's tracking and activation servers. Careful: can break Creative Cloud sign-in if you pay for Adobe apps."),
            "background-apps" => ("Stop Store apps in background", "Store apps stop running in the background. Careful: their notifications (e.g. WhatsApp) only arrive while the app is open."),
            "razer-block" => ("Block Razer auto-install", "Stops Windows auto-installing Razer software when a Razer mouse or keyboard is plugged in."),
            _ => ("", ""),
        },
        Lang::PtBr => match slug {
            "telemetry" => ("Desativar telemetria", "O Windows deixa de enviar dados de uso e diagn\u{f3}stico para a Microsoft."),
            "activity" => ("Desativar hist\u{f3}rico de atividades", "O Windows deixa de registrar uma linha do tempo com tudo o que voc\u{ea} abre e faz."),
            "consumer-features" => ("Bloquear apps sugeridos", "O Windows deixa de instalar por conta pr\u{f3}pria apps e jogos \u{ab}sugeridos\u{bb} da Loja."),
            "debloat-apps" => ("Remover apps pr\u{e9}-instalados in\u{fa}teis", "Desinstala os apps promocionais (Feedback Hub, hub do Office, Solitaire, Bing News, Copilot...). Os \u{fa}teis ficam: Calculadora, Fotos, Clima, Sticky Notes."),
            "store-search" => ("Tirar an\u{fa}ncios da Loja da busca", "A busca do menu Iniciar deixa de sugerir apps da Loja que voc\u{ea} n\u{e3}o tem."),
            "windows-ai" => ("Remover a IA do Windows (Copilot)", "Remove o Copilot, o Recall e os demais recursos de IA embutidos. Dif\u{ed}cil de reverter depois."),
            "edge-debloat" => ("Microsoft Edge sem inc\u{f4}modos", "Desativa os avisos, an\u{fa}ncios e a telemetria do Edge. O navegador continua instalado."),
            "brave-debloat" => ("Brave sem extras", "Desativa o Brave Rewards, a carteira de criptomoedas, as ofertas de VPN e a IA Leo. S\u{f3} tem efeito se o Brave estiver instalado."),
            "delivery-optimization" => ("N\u{e3}o enviar atualiza\u{e7}\u{f5}es a estranhos", "A sua internet deixa de ser usada para enviar atualiza\u{e7}\u{f5}es do Windows para PCs de outras pessoas."),
            "services-manual" => ("Menos servi\u{e7}os em segundo plano", "V\u{e1}rios servi\u{e7}os do Windows passam a iniciar somente quando necess\u{e1}rio, liberando mem\u{f3}ria."),
            "end-task" => ("Fechar apps travados com o bot\u{e3}o direito", "Adiciona a op\u{e7}\u{e3}o \u{ab}Finalizar tarefa\u{bb} ao clicar com o bot\u{e3}o direito em um app na barra de tarefas."),
            "explorer-discovery" => ("Pastas que abrem mais r\u{e1}pido", "O Windows para de analisar o conte\u{fa}do de cada pasta para \u{ab}adivinhar\u{bb} o layout \u{2014} as pastas abrem na hora."),
            "disk-cleanup" => ("Limpeza de disco", "Executa a Limpeza de Disco do Windows uma vez, liberando o espa\u{e7}o ocupado por arquivos antigos."),
            "temp-files" => ("Remover arquivos tempor\u{e1}rios", "Apaga arquivos tempor\u{e1}rios acumulados que s\u{f3} ocupam espa\u{e7}o."),
            "wpbt" => ("Bloquear programas do fabricante (WPBT)", "Impede que o firmware do fabricante do PC instale os pr\u{f3}prios programas no Windows sem pedir."),
            "adobe-block" => ("Bloquear servidores de telemetria da Adobe", "Bloqueia os servidores de rastreamento e ativa\u{e7}\u{e3}o da Adobe. Cuidado: pode impedir o login no Creative Cloud para quem assina os apps da Adobe."),
            "background-apps" => ("Impedir apps da Loja em segundo plano", "Os apps da Loja deixam de rodar em segundo plano. Cuidado: as notifica\u{e7}\u{f5}es deles (WhatsApp, por exemplo) s\u{f3} chegam com o app aberto."),
            "razer-block" => ("Bloquear instala\u{e7}\u{e3}o autom\u{e1}tica da Razer", "Impede que o Windows instale sozinho o software da Razer quando um mouse ou teclado da marca \u{e9} conectado."),
            _ => ("", ""),
        },
    }
}

/// Plain-language (title, why) for a registry toggle slug from
/// `crate::optimize::TOGGLES`.
pub fn toggle_text(lang: Lang, slug: &str) -> (&'static str, &'static str) {
    match lang {
        Lang::En => match slug {
            "dark-theme" => ("Dark theme", "Windows and apps use dark colors."),
            "file-extensions" => ("Show file extensions", "Shows the .pdf/.exe ending of file names \u{2014} helps you spot fake files."),
            "hidden-files" => ("Show hidden files", "Shows files Windows normally hides."),
            "mouse-accel-off" => ("Mouse acceleration off", "The cursor moves the same distance no matter how fast you move the mouse \u{2014} more precise, great for games."),
            "num-lock" => ("Num Lock on at startup", "The number pad already works on the login screen."),
            "sticky-keys-off" => ("Sticky Keys popup off", "No more popup when Shift is pressed 5 times."),
            "verbose-bsod" => ("Detailed error screens", "The blue error screen shows technical details instead of just a sad face."),
            "long-paths" => ("Allow long file paths", "Removes the old 260-character limit on file paths."),
            _ => ("", ""),
        },
        Lang::PtBr => match slug {
            "dark-theme" => ("Tema escuro", "O Windows e os apps passam a usar cores escuras."),
            "file-extensions" => ("Mostrar as extens\u{f5}es dos arquivos", "Mostra a termina\u{e7}\u{e3}o .pdf/.exe nos nomes de arquivo \u{2014} ajuda a reconhecer arquivos falsos."),
            "hidden-files" => ("Mostrar arquivos ocultos", "Exibe os arquivos que o Windows normalmente esconde."),
            "mouse-accel-off" => ("Desligar a acelera\u{e7}\u{e3}o do mouse", "O cursor percorre sempre a mesma dist\u{e2}ncia, n\u{e3}o importa a velocidade do movimento \u{2014} mais precis\u{e3}o, \u{f3}timo para jogos."),
            "num-lock" => ("Num Lock ativado ao iniciar", "O teclado num\u{e9}rico j\u{e1} funciona na tela de login."),
            "sticky-keys-off" => ("Desativar o aviso de Teclas de Ader\u{ea}ncia", "Elimina o aviso que aparece ao apertar Shift 5 vezes seguidas."),
            "verbose-bsod" => ("Telas de erro detalhadas", "A tela azul de erro passa a mostrar os detalhes t\u{e9}cnicos em vez de apenas uma carinha triste."),
            "long-paths" => ("Permitir caminhos longos", "Remove o antigo limite de 260 caracteres nos caminhos de arquivos."),
            _ => ("", ""),
        },
    }
}

/// Fallback "what it does" when nothing better is known: names the program
/// the entry launches.
pub fn runs_at_signin(lang: Lang, exe: &str) -> String {
    if exe.is_empty() {
        return match lang {
            Lang::En => "Registered by an app to run automatically.".to_string(),
            Lang::PtBr => "Registrado por um app para rodar automaticamente.".to_string(),
        };
    }
    match lang {
        Lang::En => format!("Starts {exe} when you sign in."),
        Lang::PtBr => format!("Inicia {exe} quando voc\u{ea} entra no Windows."),
    }
}

/// Localized "N protected items hidden" note for the System tables.
pub fn hidden_items(lang: Lang, n: usize) -> String {
    match lang {
        Lang::En => format!(
            "{n} protected item(s) hidden \u{2014} tick 'Advanced' to show them."
        ),
        Lang::PtBr => format!(
            "{n} item(ns) protegido(s) oculto(s) \u{2014} marque 'Avan\u{e7}ado' para exibir."
        ),
    }
}

/// Localized display name for an apps.json category. Categories are stored
/// in English in the catalog; unknown ones pass through unchanged.
pub fn category_display(lang: Lang, category: &str) -> &str {
    match lang {
        Lang::En => category,
        Lang::PtBr => match category {
            "Communications" => "Comunica\u{e7}\u{e3}o",
            "Development" => "Desenvolvimento",
            "Essentials" => "Essenciais",
            "Gaming" => "Jogos",
            "Internet" => "Internet",
            "Media" => "M\u{ed}dia",
            "Utilities" => "Utilit\u{e1}rios",
            other => other,
        },
    }
}

/// Friendly display name + description for a preset file's slug. Unknown
/// presets fall back to the slug itself with a generic description.
pub fn preset_display(lang: Lang, slug: &str) -> (&'static str, &'static str) {
    let t = tr(lang);
    match slug {
        "new-pc-basic" => (t.pack_basic_name, t.pack_basic_desc),
        "dev-machine" => (t.pack_dev_name, t.pack_dev_desc),
        "full" => (t.pack_full_name, t.pack_full_desc),
        _ => ("", t.pack_generic_desc),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_code_recognizes_pt_br_variants_and_defaults_to_en() {
        assert_eq!(Lang::from_code("pt-BR"), Lang::PtBr);
        assert_eq!(Lang::from_code("pt-br"), Lang::PtBr);
        assert_eq!(Lang::from_code("en"), Lang::En);
        assert_eq!(Lang::from_code("unknown"), Lang::En);
        assert_eq!(Lang::from_code(""), Lang::En);
    }

    #[test]
    fn code_round_trips_through_from_code() {
        for lang in [Lang::En, Lang::PtBr] {
            assert_eq!(Lang::from_code(lang.code()), lang);
        }
    }

    #[test]
    fn every_language_has_non_empty_core_strings() {
        for lang in [Lang::En, Lang::PtBr] {
            let t = tr(lang);
            assert!(!t.app_heading.is_empty());
            assert!(!t.run_button.is_empty());
            assert!(!t.status_completed.is_empty());
            assert!(!t.tab_summary.is_empty());
            assert!(!t.reboot_dialog_title.is_empty());
            assert!(!startup_error(lang, "SystemUpdate_Topgrade.bat").is_empty());
            assert!(status_failed(lang, 1).contains('1'));
        }
    }

    #[test]
    fn pt_br_translates_the_documented_examples() {
        let t = tr(Lang::PtBr);
        assert_eq!(t.run_button, "Executar");
        assert_eq!(t.status_completed, "Conclu\u{ed}do");
        assert_eq!(t.cat_steam, "Jogos (Steam)");
        assert_eq!(t.cat_store, "Loja Microsoft");
        assert!(t
            .reboot_detected_prefix
            .contains("Reinicializa\u{e7}\u{e3}o pendente detectada"));
    }

    #[test]
    fn technical_terms_stay_untranslated_across_languages() {
        assert_eq!(EN.cat_windows_update, PT_BR.cat_windows_update);
        assert_eq!(EN.tab_log, PT_BR.tab_log);
        assert_eq!(EN.tab_pins, PT_BR.tab_pins);
        assert_eq!(EN.cat_drivers, PT_BR.cat_drivers);
    }
}
