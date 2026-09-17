# Upkeep 1.5.8

Upkeep now checks GitHub for its own updates once when it opens. A newer stable release appears as a visible notice with a link to its release notes and downloads. The About menu shows the installed and published versions and provides a manual check button.

Checks run in the background with a timeout. Connection failures and GitHub request limits are shown separately from an up-to-date result. Older published releases never trigger downgrade notices. Drafts and prereleases are excluded. Checking does not download or execute an installer.

Validation includes numerical version comparisons, invalid responses and tags, draft/prerelease filtering, a live read-only GitHub API check, and GUI layout checks in English and Portuguese.
