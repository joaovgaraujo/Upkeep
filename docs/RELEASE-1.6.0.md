# Upkeep 1.6.0

WinGet updates no longer stop with "Unrecognized winget inventory columns". WinGet separates columns with a single space when a value is exactly as wide as its heading (for example "Unknown" under "Version"), which merged the headings and failed the whole WinGet step. The inventory now falls back to word boundaries for those headings.

Apps that WinGet lists with an "Unknown" version are no longer reinstalled or downgraded when their name already shows the same or a newer version. DiskGenius V6.2.0 was being replaced with 6.0.0 on every run. These apps are reported as skipped, and the remaining packages are updated one by one so the skipped app is not touched by a bulk upgrade.

WSL update output is now readable in the run log. wsl.exe writes UTF-16 when redirected, which appeared as "C h e c k i n g   f o r   u p d a t e s"; Upkeep now asks it for UTF-8.

Validation: new WinGet fixtures reproduce the single-space heading from real WinGet output and the Unknown-version downgrade; the heading fixture fails on 1.5.9 and passes on 1.6.0. Full PowerShell test suite and GUI tests pass. No real updates were run during validation.
