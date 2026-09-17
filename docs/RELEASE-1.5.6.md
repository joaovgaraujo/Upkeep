# Upkeep 1.5.6

Update actions now open a confirmation checklist before starting. Review each
WinGet app and its installed/available versions, uncheck anything unwanted, then
choose **Confirm and update**. Cancel or dismiss the dialog to leave everything
unchanged. Empty selections, inventory errors and pending checks cannot start a run.

The selected-app, category and failed-app retry buttons all use this review.
Category updates check WinGet before opening the final list; retries restrict that
list to previously failed apps that still have an eligible update.

Windows Update, Microsoft Store and Steam are separate category-level choices:
their individual items are discovered when those providers run. Other app and
developer-tool updaters are off by default and require explicit selection, with
an explanation that they can update apps outside the WinGet checklist. Leaving
them off skips Topgrade, launcher updates, JDownloader and Chocolatey fallback.

Confirmed WinGet IDs remain restricted when combined with other categories.
The pending-restart dialog also blocks background interaction so the approved
selection cannot change behind it. Confirmation is scrollable at high display zoom.

Includes the non-admin installer handling from [1.5.5](RELEASE-1.5.5.md).
