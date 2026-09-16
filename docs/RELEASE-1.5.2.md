# Upkeep 1.5.2

Includes all [1.5.1 features](https://github.com/joaovgaraujo/Upkeep/blob/v1.5.2/docs/RELEASE-1.5.1.md): responsive UI and Windows language defaults, robust setup, restart continuation for WSL/Docker, update previews/retries, backups and restart safeguards.

Fixes the fake WinGet inventory-failure test under GitHub Actions' strict PowerShell error handling. Expected fixture failures are captured as output and exit code 1 rather than escaping through the caller's stderr handling. Production update behavior is unchanged.
