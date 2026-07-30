<#
.SYNOPSIS
    Stops Discord from starting itself with Windows, everywhere it registers.

.DESCRIPTION
    Discord re-adds its autostart entry whenever it launches or self-updates,
    so this has to run AFTER Discord has been started, not just before.

    It registers in more than one place, which is why removing only the
    per-user Run value never stuck:

      * HKCU\...\Run\Discord
            "%LOCALAPPDATA%\Discord\Update.exe --processStart Discord.exe"
            Added by the app itself when "Open Discord" is enabled.
      * HKLM\SOFTWARE\WOW6432Node\...\Run\Discord
            "C:\ProgramData\SquirrelMachineInstalls\Discord.exe --checkInstall"
            Added by the MACHINE-WIDE Squirrel installer. Needs elevation to
            remove, and is the one that survives a per-user cleanup - and the
            reason Discord can appear twice at logon (machine entry plus the
            user one).
      * %APPDATA%\discord\settings.json -> OPEN_ON_STARTUP
            The app's own preference. Setting it false stops Discord putting
            the HKCU value back the next time it runs.

    Each Run value is also marked disabled in StartupApproved, so if Discord
    recreates the value before the next run, Windows still ignores it.

    Safe to run repeatedly. Anything already absent is skipped quietly.
    Machine-wide keys are skipped with a note when not elevated.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$changed = 0

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$elevated = Test-Elevated

# StartupApproved: byte 0 even = enabled, odd = disabled. Writing a disabled
# record makes Windows ignore the Run value even if it comes back.
$disabledBlob = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

$targets = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
       NeedsAdmin = $false; Label = 'per-user' }
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
       NeedsAdmin = $true; Label = 'machine-wide' }
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
       NeedsAdmin = $true; Label = 'machine-wide (32-bit)' }
)

foreach ($t in $targets) {
    if (-not (Test-Path $t.Run)) { continue }

    $existing = Get-ItemProperty -Path $t.Run -Name 'Discord' -ErrorAction SilentlyContinue
    if (-not $existing) { continue }

    if ($t.NeedsAdmin -and -not $elevated) {
        Write-Host "[discord] $($t.Label) autostart entry found but this process is not elevated - skipped."
        continue
    }

    try {
        Remove-ItemProperty -Path $t.Run -Name 'Discord' -ErrorAction Stop
        Write-Host "[discord] Removed $($t.Label) autostart entry."
        $changed++
    } catch {
        Write-Host "[discord] Could not remove $($t.Label) entry: $($_.Exception.Message)"
        continue
    }

    # Belt and braces: mark it disabled so a recreated value stays inert.
    try {
        if (-not (Test-Path $t.Approved)) {
            New-Item -Path $t.Approved -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $t.Approved -Name 'Discord' -Value $disabledBlob `
            -PropertyType Binary -Force -ErrorAction Stop | Out-Null
    } catch {
        # Non-fatal: the value is already gone, this is only a guard.
        Write-Verbose "[discord] StartupApproved guard not written: $($_.Exception.Message)"
    }
}

# Startup-folder shortcuts (rare, but Squirrel has used them).
$startupDirs = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
)
foreach ($dir in $startupDirs) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*iscord*' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            Write-Host "[discord] Removed startup shortcut: $($_.Name)"
            $changed++
        } catch {
            Write-Host "[discord] Could not remove $($_.Name): $($_.Exception.Message)"
        }
    }
}

# The app's own preference - stops it recreating the HKCU value next launch.
$settingsPath = Join-Path $env:APPDATA 'discord\settings.json'
if (Test-Path $settingsPath) {
    try {
        $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($json.OPEN_ON_STARTUP -ne $false) {
            if ($json.PSObject.Properties.Name -contains 'OPEN_ON_STARTUP') {
                $json.OPEN_ON_STARTUP = $false
            } else {
                $json | Add-Member -NotePropertyName 'OPEN_ON_STARTUP' -NotePropertyValue $false -Force
            }
            # WriteAllText, not Set-Content -Encoding UTF8: on PS 5.1 the
            # latter writes a UTF-8 BOM. Node's readFileSync(...,'utf8')
            # doesn't strip it and JSON.parse rejects a leading U+FEFF, so
            # Discord would fall back to defaults - dropping the very
            # OPEN_ON_STARTUP=false this function just set, and letting it
            # re-add its Run key. WriteAllText is BOM-less by default.
            [IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 20))
            Write-Host '[discord] Set OPEN_ON_STARTUP=false in settings.json.'
            $changed++
        }
    } catch {
        Write-Host "[discord] Could not update settings.json: $($_.Exception.Message)"
    }
}

if ($changed -eq 0) {
    Write-Host '[discord] Autostart already disabled - nothing to change.'
} else {
    Write-Host "[discord] Autostart disabled ($changed item(s) changed)."
}
exit 0
