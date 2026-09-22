# Upkeep 1.7.1

The initial action is now **Update everything**. It scans and opens the confirmation with all update sources selected by default. Users can review or exclude items before starting. App names use larger text, version details have stronger contrast, and the main list has a taller scrolling area. Package IDs remain available on hover in the confirmation.

Per-user balenaEtcher updates now run under the normal desktop account when Upkeep is elevated. The Squirrel bootstrapper can report success while its worker fails, leaving a partial install and the old registered version. Upkeep avoids starting that worker twice in one run, retains final inventory verification, and logs individual retry output. A successful installer exit is described as awaiting verification.

Validation: 71 Rust tests passed, one network test intentionally ignored; the main-page layout also passed separately at small sizes and high zoom in both languages. All 120 PowerShell tests passed, including 17 WinGet tests covering the normal-user worker timeout and disabled-worker cases. Formatting, Clippy with warnings denied, release build and installer build passed. A real normal-user retry restored balenaEtcher 2.1.7 and WinGet confirmed the installed version. The local installation was upgraded to 1.7.1 and its updater script hash matched the source.
