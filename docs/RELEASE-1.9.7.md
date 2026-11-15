# Upkeep 1.9.7

PowerShell 7 moves to the MSIX package by itself, and a download link the publisher broke is listed for a manual update instead of failing the winget step.

## PowerShell 7.7

winget ships PowerShell 7.7 only as an MSIX package. On a PC with 7.6 installed from the MSI, `winget upgrade` can't turn one into the other and fails with "No installed package found matching input criteria". The winget step showed as an error on every run.

When that happens, the new step `steps\Move-PowerShellToMsix.ps1`:

1. downloads the 7.7 MSIX with winget, which checks its hash, and installs it for your account;
2. checks that the MSIX is installed;
3. only then removes the 7.6 MSI.

If the download or the install fails, the MSI stays, so PowerShell 7 is never missing. It's left alone, and listed for a manual update, in two cases:

- OpenSSH uses PowerShell 7 from the MSI folder as its default shell. Removing the MSI would break SSH logins.
- PowerShell 7 windows or terminal tabs are open.

## Broken download links

On 2026-11-15, Intel's server answered the Intel Extreme Tuning Utility download with 403 Forbidden, whatever the client. winget reported the error code 0x80190193, and Upkeep counted it as a failed update. A refused download (403) or a missing file (404) is now listed under "Needs a manual update", with the reason. Upkeep tries again on the next run.

## Validation

- 202 PowerShell tests pass under Windows PowerShell 5.1. New tests cover the move (MSIX first, then the MSI is removed), no MSI install, OpenSSH using the MSI's PowerShell, the MSIX already present, a failed download (the MSI is kept), a failed MSI removal, and a 403 download in the winget step.
- 86 Rust tests pass.
