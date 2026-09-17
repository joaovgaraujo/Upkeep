# Upkeep 1.5.5

Includes the update checklist, persistent WinGet ignore list and partial-success
details from [1.5.4](RELEASE-1.5.4.md).

WinGet apps that reject administrator privileges now retry under a limited
Windows user token for either documented refusal: `0x8A15007D` (user-scope
operation blocked as administrator) or `0x8A150056` (installer prohibits elevation).
The worker checks its privileges before launching the installer. It requires a
matching Explorer desktop account in the same Windows session, so using another
administrator account does not silently update that account's user apps.

Results distinguish a completed retry, an unavailable worker and a timeout.
A timeout preserves its diagnostic directory and task because installation may
still be in progress. Upkeep does not start a forced retry or Chocolatey fallback
for an installer that rejects elevation. Wait for that installer to finish before
retrying. Other updates continue, and successful updates remain applied.

This handles confirmed elevation refusals; it does not guess install scope from
an app's display name or migrate user installations to machine-wide installs.

Validation uses fake installers and scheduled-task mocks, including localized
refusals, successful recovery, timeout, invalid completion codes, account mismatch
and paths containing apostrophes. No actual application upgrades were used in tests.

References: [WinGet return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md)
and [Windows task run levels](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/ne-taskschd-task_runlevel_type).
