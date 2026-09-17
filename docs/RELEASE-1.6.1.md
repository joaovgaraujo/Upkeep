# Upkeep 1.6.1

Adds DisplayMagician and Luminosity App as selectable utilities. DisplayMagician uses its WinGet package; Luminosity uses the Microsoft Store product 9PNVFD1CM3M5. These are independent functions: display/audio profiles and software dimming below the monitor's physical minimum. Neither is automatically installed by existing presets.

EarTrumpet now joins the Basic preset, matching its existing inclusion in Developer and Full. PowerToys remains included in all three presets.

Includes all 1.6.0 fixes: parsing tightly spaced WinGet headings, avoiding reinstall/downgrade when an Unknown-version app name shows an equal or newer version, and readable UTF-8 WSL output. The version guard is a heuristic for names containing a version, not a guarantee for every Unknown-version package.

The broader catalog grouping and profile redesign remain under review. Research into faster display switching and low-CPU nighttime dimmers continues separately.
