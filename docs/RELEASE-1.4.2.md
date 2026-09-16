# Upkeep 1.4.2

## Easier to use

- Appearance, language and text size live in one menu instead of competing
  with the title for space.
- Navigation automatically becomes a page selector when the tabs cannot fit.
- Run/Stop now appears above the update categories.
- Narrow category cards put status below the description. Cards, preset
  tiles, checklists and toolbars adapt to the available logical width.
- Data pages support horizontal scrolling instead of clipping wide tables.
- The status bar no longer reserves space for a long internal script path;
  the path is available on hover.
- Text-size choices cover 80%-200%, with a button to use Windows text size.
- The window supports smaller sizes and clamps initial size to the monitor.
  Native per-monitor display scaling remains handled by eframe/Windows.

## Language

The default is now `Language: system`. On startup, the Windows display
language selects Portuguese or English. Portuguese regional variants use the
Brazilian Portuguese translation; other unsupported languages fall back to
English. Keyboard layout and regional number/date formatting do not choose
the UI language.

Existing explicit language settings are preserved. To resume automatic
selection, choose **Appearance & language > Language > Follow Windows**.

## Validation

61 Rust tests passed, including the real seven-page layouts in both languages
at five window/scale combinations (70 cases), with scrolling. The range
includes 480x360 at 200%, 820x560 at 150%, and 4K at 150%. Layout tests check
visible text for horizontal clipping. Data pages deliberately permit
horizontal scrolling. Selected headless renders were inspected visually.
The appearance menu also opens successfully at 200% in a 480x360 window;
its contents scroll when the available height is small. These are layout
checks, not a native multi-monitor hardware test.

The prior 1.4.1 restart guards, parallel clients, accurate error reporting
and all local changes remain included.

## Next usability improvements

1. A read-only **Check for updates** preview: app names, current/new versions,
   expected restart requirements, and a clear selection before installation.
2. **Retry failed items** without repeating successful updates.
3. A per-app results screen with plain-language reasons and a suggested next
   action, with technical logs behind a Details button.
4. Move developer-tool updates into an unelevated worker where supported.
5. Stream output and measure step timings to show meaningful progress and
   choose further concurrency from actual measurements.

Windows language API:
https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-getuserdefaultuilanguage
