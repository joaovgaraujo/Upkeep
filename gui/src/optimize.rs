//! Curated optimization catalog for the "New PC" and "Optimize" pages.
//!
//! Each tweak maps to one or more winutil checkbox IDs; the selection is
//! written as a winutil `-Config` JSON and applied headless by
//! `Setup-NewPC.ps1`. Toggles are simple registry switches that the same
//! script applies natively (winutil never applies toggles in headless mode).
//! Human-readable titles/explanations live in `crate::i18n` keyed by `slug`.

/// One selectable winutil-backed tweak (or group of them).
pub struct TweakOption {
    pub slug: &'static str,
    /// winutil checkbox IDs this option expands to in the generated config.
    pub ids: &'static [&'static str],
    pub default_on: bool,
    /// Has a real trade-off worth reading before enabling.
    pub caution: bool,
}

/// The junk-apps removal set: promo/ad apps only. Deliberately keeps
/// Calculator, Photos, Weather, Sticky Notes, Alarms, Quick Assist & co.
const DEBLOAT_APPX: &[&str] = &[
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_BingSearch",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_Copilot",
];

pub const TWEAKS: &[TweakOption] = &[
    TweakOption {
        slug: "telemetry",
        ids: &["WPFTweaksTelemetry"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "activity",
        ids: &["WPFTweaksActivity"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "consumer-features",
        ids: &["WPFTweaksConsumerFeatures"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "debloat-apps",
        ids: DEBLOAT_APPX,
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "store-search",
        ids: &["WPFTweaksDisableStoreSearch"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "windows-ai",
        ids: &["WPFTweaksWindowsAI"],
        default_on: true,
        caution: true,
    },
    TweakOption {
        slug: "edge-debloat",
        ids: &["WPFTweaksEdgeDebloat"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "brave-debloat",
        ids: &["WPFTweaksBraveDebloat"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "delivery-optimization",
        ids: &["WPFTweaksDeliveryOptimization"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "services-manual",
        ids: &["WPFTweaksServices"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "end-task",
        ids: &["WPFTweaksEndTaskOnTaskbar"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "explorer-discovery",
        ids: &["WPFTweaksDisableExplorerAutoDiscovery"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "disk-cleanup",
        ids: &["WPFTweaksDiskCleanup"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "temp-files",
        ids: &["WPFTweaksDeleteTempFiles"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "wpbt",
        ids: &["WPFTweaksWPBT"],
        default_on: true,
        caution: false,
    },
    TweakOption {
        slug: "adobe-block",
        ids: &["WPFTweaksBlockAdobeNet"],
        default_on: true,
        caution: true,
    },
    TweakOption {
        slug: "background-apps",
        ids: &["WPFTweaksDisableBGapps"],
        default_on: true,
        caution: true,
    },
    TweakOption {
        slug: "razer-block",
        ids: &["WPFTweaksRazerBlock"],
        default_on: true,
        caution: false,
    },
];

/// One registry toggle applied natively by Setup-NewPC.ps1 (`-Toggles`).
pub struct ToggleOption {
    pub slug: &'static str,
    pub default_on: bool,
}

pub const TOGGLES: &[ToggleOption] = &[
    ToggleOption {
        slug: "dark-theme",
        default_on: true,
    },
    ToggleOption {
        slug: "file-extensions",
        default_on: true,
    },
    ToggleOption {
        slug: "hidden-files",
        default_on: true,
    },
    ToggleOption {
        slug: "mouse-accel-off",
        default_on: true,
    },
    ToggleOption {
        slug: "num-lock",
        default_on: true,
    },
    ToggleOption {
        slug: "sticky-keys-off",
        default_on: true,
    },
    ToggleOption {
        slug: "verbose-bsod",
        default_on: true,
    },
    ToggleOption {
        slug: "long-paths",
        default_on: true,
    },
];

/// Renders the winutil `-Config` JSON (a flat array of checkbox IDs) for the
/// tweaks whose parallel `selected` flag is set.
pub fn winutil_config_json(selected: &[bool]) -> String {
    let ids: Vec<&str> = TWEAKS
        .iter()
        .zip(selected)
        .filter(|(_, sel)| **sel)
        .flat_map(|(t, _)| t.ids.iter().copied())
        .collect();
    serde_json::to_string_pretty(&ids).unwrap_or_else(|_| "[]".to_string())
}

/// Comma-joined toggle slugs for Setup-NewPC.ps1 `-Toggles`.
pub fn toggles_arg(selected: &[bool]) -> String {
    TOGGLES
        .iter()
        .zip(selected)
        .filter(|(_, sel)| **sel)
        .map(|(t, _)| t.slug)
        .collect::<Vec<_>>()
        .join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_json_expands_groups_and_respects_selection() {
        let mut selected = vec![false; TWEAKS.len()];
        // Enable only debloat-apps (a group) and telemetry.
        for (i, t) in TWEAKS.iter().enumerate() {
            if t.slug == "debloat-apps" || t.slug == "telemetry" {
                selected[i] = true;
            }
        }
        let json = winutil_config_json(&selected);
        let parsed: Vec<String> = serde_json::from_str(&json).unwrap();
        assert!(parsed.contains(&"WPFTweaksTelemetry".to_string()));
        assert!(parsed.contains(&"WPFAppxMicrosoft_Copilot".to_string()));
        assert_eq!(parsed.len(), 1 + DEBLOAT_APPX.len());
    }

    #[test]
    fn toggles_arg_joins_selected_slugs() {
        let mut selected = vec![false; TOGGLES.len()];
        selected[0] = true;
        selected[3] = true;
        let arg = toggles_arg(&selected);
        assert_eq!(arg, "dark-theme,mouse-accel-off");
    }

    #[test]
    fn every_option_has_text_in_both_languages() {
        use crate::i18n::{tweak_text, toggle_text, Lang};
        for lang in [Lang::En, Lang::PtBr] {
            for t in TWEAKS {
                let (title, why) = tweak_text(lang, t.slug);
                assert!(!title.is_empty(), "missing tweak title: {} {:?}", t.slug, lang);
                assert!(!why.is_empty(), "missing tweak why: {} {:?}", t.slug, lang);
            }
            for t in TOGGLES {
                let (title, why) = toggle_text(lang, t.slug);
                assert!(!title.is_empty(), "missing toggle title: {} {:?}", t.slug, lang);
                assert!(!why.is_empty(), "missing toggle why: {} {:?}", t.slug, lang);
            }
        }
    }

    #[test]
    fn all_slugs_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for t in TWEAKS {
            assert!(seen.insert(t.slug), "duplicate tweak slug {}", t.slug);
        }
        let mut seen = std::collections::HashSet::new();
        for t in TOGGLES {
            assert!(seen.insert(t.slug), "duplicate toggle slug {}", t.slug);
        }
    }
}
