//! Two-palette theme: a dark "slate/graphite" look and a matching light one,
//! both built on egui's own visuals, with a green accent reserved for the
//! primary (Run) action.
//!
//! Both palettes are registered with egui up front via `set_visuals_of`, so
//! egui itself flips chrome (panels, widgets, text) when the OS theme changes
//! or the user picks an override. Our *own* colors -- card fills, status
//! chips, log tag colors -- can't live in `Visuals`, so they're looked up
//! through the accessor functions below, which read whichever palette matches
//! the theme egui is currently painting with. `sync()` refreshes that at the
//! top of every frame; forgetting to call it just means stale (but still
//! valid) colors, never a panic.

use egui::{Color32, CornerRadius, Stroke, Theme};
use std::sync::atomic::{AtomicBool, Ordering};

/// Every color that isn't already carried by `egui::Visuals`.
pub struct Palette {
    // Surfaces used by the card-based pages.
    pub card_bg: Color32,
    pub card_bg_selected: Color32,
    pub card_stroke: Color32,

    pub subtle_text: Color32,
    pub log_default: Color32,

    pub accent_green: Color32,
    pub accent_green_hover: Color32,
    /// Fill for the disabled/dimmed primary button.
    pub accent_green_dim: Color32,

    pub status_idle: Color32,
    pub status_running: Color32,
    pub status_ok: Color32,
    pub status_error: Color32,
    pub status_skipped: Color32,
    pub warn_amber: Color32,

    /// Banner backgrounds (warning / caution / success).
    pub banner_warn_bg: Color32,
    pub banner_caution_bg: Color32,
    pub banner_ok_bg: Color32,

    // egui `Visuals` inputs, kept here so both palettes are described in one
    // place.
    window_bg: Color32,
    panel_bg: Color32,
    surface: Color32,
    surface_hi: Color32,
    stroke: Color32,
    text: Color32,
    code_bg: Color32,
    /// `fg_stroke` for hovered/active widgets: the strongest text color.
    text_strong: Color32,
}

pub const DARK: Palette = Palette {
    card_bg: Color32::from_rgb(0x22, 0x24, 0x28),
    card_bg_selected: Color32::from_rgb(0x24, 0x30, 0x26),
    card_stroke: Color32::from_rgb(0x3a, 0x3d, 0x42),

    subtle_text: Color32::from_gray(0x9a),
    log_default: Color32::from_gray(0xc8),

    accent_green: Color32::from_rgb(0x43, 0xa0, 0x47),
    // Deepened rather than lightened on hover. The obvious dark-theme move is
    // to lighten (#4caf50), but white label text only reaches 2.78:1 on that,
    // below the 3.0 the tests enforce - the base green is already near the
    // edge at 3.30, so there is no headroom upward.
    accent_green_hover: Color32::from_rgb(0x3d, 0x92, 0x41),
    accent_green_dim: Color32::from_rgb(0x2e, 0x5c, 0x31),

    status_idle: Color32::from_gray(0x7a),
    status_running: Color32::from_rgb(0x5c, 0x9c, 0xe6),
    status_ok: Color32::from_rgb(0x5c, 0xc4, 0x6e),
    status_error: Color32::from_rgb(0xe0, 0x5c, 0x5c),
    status_skipped: Color32::from_gray(0x55),
    warn_amber: Color32::from_rgb(0xe0, 0xa5, 0x3a),

    banner_warn_bg: Color32::from_rgb(0x3a, 0x28, 0x10),
    banner_caution_bg: Color32::from_rgb(0x3a, 0x30, 0x10),
    banner_ok_bg: Color32::from_rgb(0x1d, 0x30, 0x22),

    window_bg: Color32::from_rgb(0x17, 0x18, 0x1a),
    panel_bg: Color32::from_rgb(0x1e, 0x20, 0x23),
    surface: Color32::from_rgb(0x26, 0x28, 0x2c),
    surface_hi: Color32::from_rgb(0x2f, 0x31, 0x36),
    stroke: Color32::from_rgb(0x3a, 0x3d, 0x42),
    text: Color32::from_rgb(0xe4, 0xe4, 0xe6),
    code_bg: Color32::from_rgb(0x14, 0x15, 0x17),
    text_strong: Color32::WHITE,
};

/// Light counterpart. Accent/status hues are darkened rather than reused:
/// the dark palette's mid-tones (amber, the pale greens/blues) fall well
/// under 4.5:1 against a white card and were the reason the light theme was
/// unreadable.
pub const LIGHT: Palette = Palette {
    card_bg: Color32::from_rgb(0xff, 0xff, 0xff),
    card_bg_selected: Color32::from_rgb(0xe6, 0xf3, 0xe8),
    card_stroke: Color32::from_rgb(0xd0, 0xd4, 0xda),

    subtle_text: Color32::from_gray(0x5e),
    log_default: Color32::from_rgb(0x24, 0x26, 0x2a),

    accent_green: Color32::from_rgb(0x2e, 0x7d, 0x32),
    accent_green_hover: Color32::from_rgb(0x38, 0x8e, 0x3c),
    // Muted, but still dark enough to carry white label text: this is the
    // fill behind the *disabled* Run/Install/Apply buttons, and egui fades
    // disabled widgets toward the window fill on top of this.
    accent_green_dim: Color32::from_rgb(0x5f, 0x7d, 0x61),

    status_idle: Color32::from_gray(0x6a),
    status_running: Color32::from_rgb(0x15, 0x65, 0xc0),
    status_ok: Color32::from_rgb(0x2e, 0x7d, 0x32),
    status_error: Color32::from_rgb(0xc0, 0x28, 0x28),
    status_skipped: Color32::from_gray(0x8a),
    warn_amber: Color32::from_rgb(0x96, 0x5e, 0x00),

    banner_warn_bg: Color32::from_rgb(0xfd, 0xf0, 0xd8),
    banner_caution_bg: Color32::from_rgb(0xfc, 0xf6, 0xdc),
    banner_ok_bg: Color32::from_rgb(0xe4, 0xf4, 0xe7),

    window_bg: Color32::from_rgb(0xff, 0xff, 0xff),
    panel_bg: Color32::from_rgb(0xf1, 0xf3, 0xf5),
    surface: Color32::from_rgb(0xe5, 0xe8, 0xec),
    surface_hi: Color32::from_rgb(0xd8, 0xdc, 0xe2),
    stroke: Color32::from_rgb(0xc2, 0xc7, 0xce),
    text: Color32::from_rgb(0x1c, 0x1e, 0x21),
    code_bg: Color32::from_rgb(0xec, 0xee, 0xf1),
    text_strong: Color32::BLACK,
};

/// Which palette the accessors below read. Mirrors `ctx.theme()`; see
/// [`sync`].
static IS_DARK: AtomicBool = AtomicBool::new(true);

/// Point the palette accessors at the theme egui is about to paint with.
/// Call once per frame, before any drawing.
pub fn sync(ctx: &egui::Context) {
    IS_DARK.store(ctx.theme() == Theme::Dark, Ordering::Relaxed);
}

/// The palette for the theme currently being painted.
pub fn palette() -> &'static Palette {
    if IS_DARK.load(Ordering::Relaxed) {
        &DARK
    } else {
        &LIGHT
    }
}

macro_rules! color_accessors {
    ($($name:ident),* $(,)?) => {
        $(
            #[inline]
            pub fn $name() -> Color32 {
                palette().$name
            }
        )*
    };
}

color_accessors!(
    card_bg,
    card_bg_selected,
    card_stroke,
    subtle_text,
    log_default,
    accent_green,
    accent_green_dim,
    status_idle,
    status_running,
    status_ok,
    status_error,
    status_skipped,
    warn_amber,
    banner_warn_bg,
    banner_caution_bg,
    banner_ok_bg,
);

/// Reserved for a future hovered-Run-button treatment.
#[allow(dead_code)]
pub fn accent_green_hover() -> Color32 {
    palette().accent_green_hover
}

/// Text drawn on top of `accent_green` / `accent_green_dim` fills. White in
/// both themes -- the accent is dark enough either way.
pub fn on_accent() -> Color32 {
    Color32::WHITE
}

/// A rounded surface frame used for the card-based pages.
pub fn card() -> egui::Frame {
    let p = palette();
    egui::Frame::new()
        .fill(p.card_bg)
        .stroke(Stroke::new(1.0_f32, p.card_stroke))
        .corner_radius(CornerRadius::same(10))
        .inner_margin(egui::Margin::same(14))
}

/// Card variant with the selected/accent border.
pub fn card_selected() -> egui::Frame {
    let p = palette();
    egui::Frame::new()
        .fill(p.card_bg_selected)
        .stroke(Stroke::new(1.5_f32, p.accent_green))
        .corner_radius(CornerRadius::same(10))
        .inner_margin(egui::Margin::same(14))
}

/// Stable-ish color per `[tag]` for the log view. Errors/warnings are
/// special-cased separately in the log renderer.
pub fn tag_color(tag: &str) -> Color32 {
    if is_warning_tag(tag) {
        return warn_amber();
    }
    if IS_DARK.load(Ordering::Relaxed) {
        match tag {
            "setup" => Color32::from_rgb(0x8a, 0x8a, 0xe0),
            "pins" => Color32::from_rgb(0x9a, 0x7a, 0xd6),
            "discord" => Color32::from_rgb(0x7a, 0x8a, 0xe6),
            "ea" => Color32::from_rgb(0xe0, 0x8a, 0x4a),
            "store" | "winupdate" => Color32::from_rgb(0x4a, 0xa8, 0xe6),
            "launch" => Color32::from_rgb(0x6a, 0xc8, 0xa8),
            "jdownloader" => Color32::from_rgb(0xd6, 0xc0, 0x4a),
            "winget" => Color32::from_rgb(0x5c, 0xc4, 0x6e),
            "steam" => Color32::from_rgb(0x8a, 0xa8, 0xc8),
            "explicit" => Color32::from_rgb(0xc8, 0x9a, 0x4a),
            // "run" and anything unrecognized share the default log color.
            _ => DARK.log_default,
        }
    } else {
        // Same hues, darkened to stay legible on a white log background.
        match tag {
            "setup" => Color32::from_rgb(0x44, 0x44, 0xa8),
            "pins" => Color32::from_rgb(0x6a, 0x40, 0xa0),
            "discord" => Color32::from_rgb(0x3c, 0x4c, 0xac),
            "ea" => Color32::from_rgb(0xa8, 0x50, 0x10),
            "store" | "winupdate" => Color32::from_rgb(0x14, 0x6e, 0xa8),
            "launch" => Color32::from_rgb(0x18, 0x74, 0x60),
            "jdownloader" => Color32::from_rgb(0x84, 0x6c, 0x00),
            "winget" => Color32::from_rgb(0x2c, 0x84, 0x3c),
            "steam" => Color32::from_rgb(0x3c, 0x5c, 0x8c),
            "explicit" => Color32::from_rgb(0x8c, 0x5c, 0x10),
            _ => LIGHT.log_default,
        }
    }
}

pub fn is_warning_tag(tag: &str) -> bool {
    matches!(tag, "error" | "warn" | "timeout" | "stderr")
}

/// User-facing theme choice, persisted in `settings.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThemeChoice {
    /// Follow the OS light/dark setting.
    #[default]
    System,
    Light,
    Dark,
}

impl ThemeChoice {
    pub fn from_code(code: &str) -> Self {
        match code.to_ascii_lowercase().as_str() {
            "light" => ThemeChoice::Light,
            "dark" => ThemeChoice::Dark,
            _ => ThemeChoice::System,
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            ThemeChoice::System => "system",
            ThemeChoice::Light => "light",
            ThemeChoice::Dark => "dark",
        }
    }

    fn preference(self) -> egui::ThemePreference {
        match self {
            ThemeChoice::System => egui::ThemePreference::System,
            ThemeChoice::Light => egui::ThemePreference::Light,
            ThemeChoice::Dark => egui::ThemePreference::Dark,
        }
    }
}

/// Apply the user's theme choice. Safe to call every time it changes.
pub fn set_choice(ctx: &egui::Context, choice: ThemeChoice) {
    ctx.set_theme(choice.preference());
    sync(ctx);
}

/// Register both palettes and the shared type scale/spacing. Called once at
/// startup; egui then picks between them on its own.
pub fn apply(ctx: &egui::Context) {
    ctx.set_visuals_of(Theme::Dark, visuals(&DARK, egui::Visuals::dark()));
    ctx.set_visuals_of(Theme::Light, visuals(&LIGHT, egui::Visuals::light()));
    sync(ctx);

    // Larger, friendlier type scale and roomier spacing than egui defaults.
    // Sized for a 14" 1080p laptop at 100% Windows scaling, where the old
    // 15pt body text read as cramped; `set_scale` takes it further.
    //
    // `all_styles_mut`, NOT `style_mut`: egui keeps a separate `Style` per
    // theme, and `style_mut` only touches the one currently active. Using it
    // here left whichever theme wasn't active on egui's stock 12.5pt body
    // text, so switching to Light threw the whole type scale away.
    ctx.all_styles_mut(|style| {
        use egui::{FontFamily, FontId, TextStyle};
        style.text_styles.insert(
            TextStyle::Heading,
            FontId::new(26.0, FontFamily::Proportional),
        );
        style
            .text_styles
            .insert(TextStyle::Body, FontId::new(16.5, FontFamily::Proportional));
        style.text_styles.insert(
            TextStyle::Button,
            FontId::new(16.5, FontFamily::Proportional),
        );
        // Small is used for captions, the "what it does" lines and table
        // cells - it was the worst offender at 12.5.
        style.text_styles.insert(
            TextStyle::Small,
            FontId::new(14.0, FontFamily::Proportional),
        );
        style.text_styles.insert(
            TextStyle::Monospace,
            FontId::new(14.0, FontFamily::Monospace),
        );
        style.spacing.item_spacing = egui::vec2(10.0, 9.0);
        style.spacing.button_padding = egui::vec2(14.0, 8.0);
    });
}

/// Text-size choices offered in the UI, as egui zoom factors. Zoom scales
/// fonts *and* spacing/widget hit-boxes together, which is what you want on a
/// small screen - bumping only the font sizes leaves buttons cramped.
pub const UI_SCALES: [f32; 5] = [1.0, 1.15, 1.3, 1.5, 1.75];

/// Clamp an arbitrary persisted value into the supported range.
pub fn clamp_scale(scale: f32) -> f32 {
    if !scale.is_finite() {
        return 1.0;
    }
    scale.clamp(0.8, 2.0)
}

/// Apply the user's text-size preference. egui also honours Ctrl+Plus /
/// Ctrl+Minus on its own; this just makes the choice explicit and persistent.
pub fn set_scale(ctx: &egui::Context, scale: f32) {
    ctx.set_zoom_factor(clamp_scale(scale));
}

fn visuals(p: &Palette, base: egui::Visuals) -> egui::Visuals {
    let mut visuals = base;

    visuals.override_text_color = Some(p.text);
    visuals.panel_fill = p.panel_bg;
    visuals.window_fill = p.panel_bg;
    visuals.extreme_bg_color = p.window_bg;
    visuals.faint_bg_color = p.surface;
    visuals.code_bg_color = p.code_bg;
    visuals.selection.bg_fill = p.accent_green_dim;
    visuals.selection.stroke = Stroke::new(1.0f32, p.accent_green);
    visuals.hyperlink_color = p.status_running;
    visuals.warn_fg_color = p.warn_amber;
    visuals.error_fg_color = p.status_error;

    visuals.widgets.noninteractive.bg_fill = p.panel_bg;
    visuals.widgets.noninteractive.weak_bg_fill = p.panel_bg;
    visuals.widgets.noninteractive.fg_stroke = Stroke::new(1.0f32, p.text);
    visuals.widgets.noninteractive.bg_stroke = Stroke::new(1.0f32, p.stroke);

    visuals.widgets.inactive.bg_fill = p.surface;
    visuals.widgets.inactive.weak_bg_fill = p.surface;
    visuals.widgets.inactive.fg_stroke = Stroke::new(1.0f32, p.text);
    visuals.widgets.inactive.bg_stroke = Stroke::new(1.0f32, p.stroke);

    visuals.widgets.hovered.bg_fill = p.surface_hi;
    visuals.widgets.hovered.weak_bg_fill = p.surface_hi;
    visuals.widgets.hovered.fg_stroke = Stroke::new(1.0f32, p.text_strong);
    visuals.widgets.hovered.bg_stroke = Stroke::new(1.0f32, p.accent_green);

    visuals.widgets.active.bg_fill = p.surface_hi;
    visuals.widgets.active.weak_bg_fill = p.surface_hi;
    visuals.widgets.active.fg_stroke = Stroke::new(1.0f32, p.text_strong);
    visuals.widgets.active.bg_stroke = Stroke::new(1.0f32, p.accent_green);

    // egui's light default draws selected/open widgets nearly white-on-white;
    // reuse the active treatment so open combo boxes stay visible.
    visuals.widgets.open.bg_fill = p.surface_hi;
    visuals.widgets.open.weak_bg_fill = p.surface_hi;
    visuals.widgets.open.fg_stroke = Stroke::new(1.0f32, p.text);
    visuals.widgets.open.bg_stroke = Stroke::new(1.0f32, p.stroke);

    let rounding = CornerRadius::same(8);
    visuals.window_corner_radius = rounding;
    visuals.menu_corner_radius = rounding;
    for w in [
        &mut visuals.widgets.noninteractive,
        &mut visuals.widgets.inactive,
        &mut visuals.widgets.hovered,
        &mut visuals.widgets.active,
        &mut visuals.widgets.open,
    ] {
        w.corner_radius = rounding;
    }

    visuals
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Relative luminance per WCAG 2.x.
    fn luminance(c: Color32) -> f32 {
        let f = |v: u8| {
            let v = v as f32 / 255.0;
            if v <= 0.039_28 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * f(c.r()) + 0.7152 * f(c.g()) + 0.0722 * f(c.b())
    }

    fn contrast(a: Color32, b: Color32) -> f32 {
        let (la, lb) = (luminance(a), luminance(b));
        let (hi, lo) = if la > lb { (la, lb) } else { (lb, la) };
        (hi + 0.05) / (lo + 0.05)
    }

    /// The bug this palette split fixes: dark-palette foregrounds were being
    /// painted on light-theme surfaces (and vice versa). Guard both.
    #[test]
    fn foregrounds_are_legible_on_their_own_card() {
        for (name, p) in [("dark", &DARK), ("light", &LIGHT)] {
            for (label, fg) in [
                ("text", p.text),
                ("subtle_text", p.subtle_text),
                ("log_default", p.log_default),
                ("status_ok", p.status_ok),
                ("status_error", p.status_error),
                ("status_running", p.status_running),
                ("warn_amber", p.warn_amber),
                ("accent_green", p.accent_green),
            ] {
                let c = contrast(fg, p.card_bg);
                assert!(
                    c >= 3.0,
                    "{name}/{label} contrast {c:.2} against card_bg is too low"
                );
            }
        }
    }

    #[test]
    fn log_tag_colors_are_legible_on_the_log_background() {
        let tags = [
            "setup",
            "pins",
            "discord",
            "ea",
            "store",
            "winupdate",
            "launch",
            "jdownloader",
            "winget",
            "steam",
            "explicit",
            "run",
            "error",
        ];
        for (is_dark, p) in [(true, &DARK), (false, &LIGHT)] {
            IS_DARK.store(is_dark, Ordering::Relaxed);
            for tag in tags {
                let c = contrast(tag_color(tag), p.window_bg);
                assert!(
                    c >= 3.0,
                    "tag [{tag}] contrast {c:.2} on the {} log background is too low",
                    if is_dark { "dark" } else { "light" }
                );
            }
        }
        IS_DARK.store(true, Ordering::Relaxed);
    }

    /// Covers the *disabled* fill too -- the enabled accent passed easily
    /// while `accent_green_dim` sat at 2.61:1 against white in the light
    /// palette, which is the state the Run button spends most of its time in.
    #[test]
    fn on_accent_text_is_legible_on_the_run_button() {
        for (name, p) in [("dark", &DARK), ("light", &LIGHT)] {
            for (state, fill) in [
                ("enabled", p.accent_green),
                ("hovered", p.accent_green_hover),
                ("disabled", p.accent_green_dim),
            ] {
                let c = contrast(on_accent(), fill);
                assert!(
                    c >= 3.0,
                    "{name} {state} run-button text contrast {c:.2} is too low"
                );
            }
        }
    }

    /// `apply()` must write the type scale into BOTH themes' styles.
    /// `ctx.style_mut` silently writes only the active one.
    #[test]
    fn type_scale_is_applied_to_both_themes() {
        let ctx = egui::Context::default();
        apply(&ctx);
        for theme in [Theme::Dark, Theme::Light] {
            let body = ctx.style_of(theme).text_styles[&egui::TextStyle::Body].size;
            let small = ctx.style_of(theme).text_styles[&egui::TextStyle::Small].size;
            assert!(
                body >= 16.0 && small >= 13.5,
                "{theme:?} kept egui's default type scale (body {body}, small {small})"
            );
        }
    }

    #[test]
    fn theme_choice_round_trips() {
        for choice in [ThemeChoice::System, ThemeChoice::Light, ThemeChoice::Dark] {
            assert_eq!(ThemeChoice::from_code(choice.code()), choice);
        }
        assert_eq!(ThemeChoice::from_code("nonsense"), ThemeChoice::System);
        assert_eq!(ThemeChoice::from_code("DARK"), ThemeChoice::Dark);
    }
}
