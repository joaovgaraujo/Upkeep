# Called only for selected WSL/Docker installs; parent imposes a time limit.
$ErrorActionPreference = 'Stop'
try {
    $restart = $false
    foreach ($name in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
        if ($feature.State -eq 'EnablePending') { $restart = $true; continue }
        if ($feature.State -ne 'Enabled') {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
            # Conservatively require a boot before a dependent installer starts.
            $restart = $true
        }
    }
    if ($restart) { exit 3010 }
    # Install the modern WSL runtime without creating or launching a distro.
    & wsl.exe --install --no-distribution --no-launch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & wsl.exe --update --web-download
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & wsl.exe --version
    if ($LASTEXITCODE -ne 0) { throw 'Modern WSL runtime could not be verified.' }
    exit 0
} catch { Write-Warning $_; exit 1 }
