# Upkeep 1.9.0

winget downloads every pending package at once and installs each one as its download finishes. A normal-user step no longer stalls a run for minutes when PowerShell can't start for your normal user.

## Downloads ahead, installs as they finish

For the big packages, the download is most of the time: CUDA took 224 s, and Ollama 106 to 126 s. Each download used to start only after the previous install had finished. winget reuses an installer it already finds in its own cache: a file named after the installer's SHA-256 in `%TEMP%\WinGet\<Id>.<Version>\`. Verified with winget 1.29 on 2026-11-07: "Existing installer file hash matches. Will use existing installer.", and an install that took 2 s with no download.

So after its scan, the winget step now downloads every pending package with `winget download`, four at a time, and places each installer in that cache. Both install lanes take whichever package's download has finished next. Packages with special handling still go first, in order. A download that fails, or takes over 15 minutes, only means winget downloads that package itself. If winget would pick a different installer than the one downloaded, the hash differs, and winget downloads it as usual. Nothing is installed without winget's hash check. `UPKEEP_NO_PREFETCH=1` turns this off.

Two approaches were tried first and don't work. Installing from a local manifest (`winget install --manifest`, which needs the `LocalManifestFiles` admin setting) fails: winget's downloader rejects `file://` URLs and plain paths with "InternetOpenUrl() failed". Serving the files over `http://127.0.0.1` works, but the cache needs no setting and no web server.

## A normal-user step can't stall the run

On the test laptop on 2026-11-07, the two steps that run as the normal user took 16 and 7 minutes out of a 51-minute run, and almost all of that passed before their command even started. The cause was a dead NFS mount: a network drive whose server was down, mounted in the user's logon by a PowerShell profile. Windows PowerShell checks every drive when it starts, so every normal-user PowerShell hung. `cmd.exe` and elevated processes, which don't see that mount, started in under a second.

Before its first normal-user command, Upkeep now checks once, and at most every 10 minutes, that Windows PowerShell starts for the normal user within 20 seconds. When it doesn't, normal-user updates are skipped for that run, with the reason: "a network drive that is not responding". That step then costs 20 seconds instead of minutes.

## Validation

- 178 PowerShell tests pass under Windows PowerShell 5.1. New: packages downloaded ahead into winget's cache before install, and a normal-user step skipped without launching anything when the probe fails. The fake winget used by the tests now copes with being called from several runspaces at once.
- The cache reuse was checked by hand with Microsoft.Sysinternals.Whois on this PC: downloaded, placed by hash, then a normal `winget install` used it.
