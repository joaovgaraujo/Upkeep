<#
.SYNOPSIS
    Updates RustDesk from its signed GitHub release.

.DESCRIPTION
    winget has no RustDesk package (none in winget-pkgs, checked 2026-11-13),
    so winget lists it as ARP\Machine\X64\RustDesk and nothing updated it:
    1.5.1 stayed installed while 1.5.3 was out.

    This step reads the latest release from GitHub, downloads the installer
    of the kind that is installed (.exe or .msi), checks the SHA-256 GitHub
    publishes for it and its Authenticode signature (same signer as the
    installed RustDesk.exe), and installs it silently.

    The installer also installs and starts the RustDesk service, and starts
    RustDesk. Whatever was not there before is put back: a service that did
    not exist is removed, a service keeps its start type, new startup entries
    are removed, and RustDesk processes that were not running are closed.

    While someone is connected to this PC through RustDesk (its connection
    manager, `--cm`, is running), the update is not installed: it would end
    that session. It is listed for a manual update instead.

    Chocolatey updates a RustDesk it installed; this step leaves that one alone.

.NOTES
    Exit codes: 0 = current, updated or listed; 2 = not installed or not ours; 1 = error.
#>
[CmdletBinding()]
param(
    [string]$ReleaseApi = 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest',
    [string]$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk',
    [string]$ChocoLib = (Join-Path $(if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }) 'lib\rustdesk'),
    [string]$ServiceName = 'RustDesk',
    [int]$TimeoutMin = 5,
    [string]$ReportDir = (Join-Path $env:LOCALAPPDATA 'Upkeep\Reports'),
    # Tests: stop after deciding, before downloading.
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-Installed {
    $p = Get-ItemProperty -LiteralPath $UninstallKey -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.DisplayVersion) { return $null }
    $p
}
function ConvertTo-Version([string]$Text) {
    $v = $null
    if ([version]::TryParse(($Text.Trim() -replace '^v', '' -replace '[^0-9.].*$', ''), [ref]$v)) { $v } else { $null }
}
function Get-RunEntries {
    $found = @()
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -notlike 'PS*' -and "$($p.Value)" -match '(?i)rustdesk') { $found += [pscustomobject]@{ Key = $k; Name = $p.Name } }
        }
    }
    $found
}
function Get-RustDeskProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name = 'rustdesk.exe'" -ErrorAction SilentlyContinue)
}

$installed = Get-Installed
if (-not $installed) { Write-Host '[rustdesk] RustDesk is not installed - skipping.'; exit 2 }
if (Test-Path -LiteralPath $ChocoLib) { Write-Host '[rustdesk] RustDesk was installed by Chocolatey, which updates it - skipping.'; exit 2 }
$current = ConvertTo-Version $installed.DisplayVersion
$isMsi = "$($installed.WindowsInstaller)" -eq '1'

try {
    $release = Invoke-RestMethod -Uri $ReleaseApi -UserAgent 'Upkeep-RustDesk' -TimeoutSec 30 `
        -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
} catch {
    Write-Host "[rustdesk] Could not read RustDesk's latest release from GitHub: $($_.Exception.Message)"
    exit 1
}
$latest = ConvertTo-Version "$($release.tag_name)"
if (-not $current -or -not $latest) {
    Write-Host "[rustdesk] Could not compare versions (installed '$($installed.DisplayVersion)', latest '$($release.tag_name)')."
    exit 1
}
if ($latest -le $current) { Write-Host "[rustdesk] Already current ($($installed.DisplayVersion))."; exit 0 }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$ext = if ($isMsi) { 'msi' } else { 'exe' }
$asset = @($release.assets | Where-Object { $_.name -match "^rustdesk-$([regex]::Escape("$($release.tag_name)".TrimStart('v')))-$arch\.$ext$" })[0]
if (-not $asset) { Write-Host "[rustdesk] RustDesk $latest has no $arch .$ext installer on GitHub - skipping."; exit 2 }
Write-Host "[rustdesk] RustDesk $current -> $latest available."

# Someone connected through RustDesk would lose the session.
$cm = @(Get-RustDeskProcesses | Where-Object { "$($_.CommandLine)" -match '\s--cm(\s|$)' })
if ($cm.Count) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    ConvertTo-Json -InputObject @([pscustomobject]@{
            Source = 'rustdesk'; Id = 'RustDesk'; Name = 'RustDesk'; Current = "$current"; Available = "$latest"
            Reason = 'someone is connected to this PC through RustDesk, and updating would end that session'
            Fix = 'run Upkeep again when nobody is connected, or install it from https://github.com/rustdesk/rustdesk/releases'
        }) | Set-Content -LiteralPath (Join-Path $ReportDir 'manual-updates-rustdesk.json') -Encoding UTF8
    Write-Host '[rustdesk] Someone is connected through RustDesk - not updating now; listed at the end of the run.'
    exit 0
}
if ($CheckOnly) { Write-Host "[rustdesk] Would install $($asset.name)."; exit 0 }

$work = Join-Path $env:TEMP ('Upkeep_rustdesk_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$file = Join-Path $work $asset.name
$code = 0
# What the installer may add, as it was before.
$svcBefore = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$svcType = if ($svcBefore) { "$($svcBefore.StartType)" } else { '' }
$svcStatus = if ($svcBefore) { "$($svcBefore.Status)" } else { '' }
$runBefore = @(Get-RunEntries | ForEach-Object { "$($_.Key)|$($_.Name)" })
$procBefore = @(Get-RustDeskProcesses | ForEach-Object { $_.ProcessId })
try {
    Write-Host "[rustdesk] Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing -UserAgent 'Upkeep-RustDesk' -TimeoutSec 600
    if ("$($asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') {
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Matches[1].ToUpper()) { throw 'the download does not match the SHA-256 GitHub lists for it' }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -ne 'Valid') { throw "the installer's signature is not valid ($($sig.Status))" }
    $exe = Join-Path "$($installed.InstallLocation)" 'RustDesk.exe'
    $have = if (Test-Path -LiteralPath $exe) { Get-AuthenticodeSignature -LiteralPath $exe } else { $null }
    if ($have -and $have.Status -eq 'Valid' -and $have.SignerCertificate.Subject -ne $sig.SignerCertificate.Subject) {
        throw "the installer is signed by '$($sig.SignerCertificate.Subject)', not by the signer of the installed RustDesk"
    }

    Write-Host "[rustdesk] Installing $latest silently..."
    $p = if ($isMsi) {
        Start-Process msiexec.exe -ArgumentList "/i `"$file`" /qn /norestart" -PassThru -WindowStyle Hidden
    } else {
        Start-Process $file -ArgumentList '--silent-install' -PassThru -WindowStyle Hidden
    }
    $null = $p.Handle
    # The .exe hands the install to a copy of itself and returns: wait for
    # the version Windows lists instead.
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    do {
        Start-Sleep -Seconds 2
        $now = ConvertTo-Version "$((Get-Installed).DisplayVersion)"
    } while ($now -ne $latest -and (Get-Date) -lt $deadline)
    if ($now -eq $latest) {
        # Let the installer finish starting what it starts before undoing it.
        Start-Sleep -Seconds 5
        Write-Host "[rustdesk] Updated $current -> $latest."
    } else {
        Write-Host "[rustdesk] The installer ran, but Windows still lists RustDesk $($installed.DisplayVersion) after $TimeoutMin min."
        $code = 1
    }
} catch {
    Write-Host "[rustdesk] Could not update RustDesk: $($_.Exception.Message)"
    $code = 1
} finally {
    # Put back what the installer added.
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and -not $svcBefore) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        Write-Host '[rustdesk] Removed the RustDesk service the installer added (it was not installed before).'
    } elseif ($svc) {
        if ("$($svc.StartType)" -ne $svcType) { Set-Service -Name $ServiceName -StartupType $svcType -ErrorAction SilentlyContinue }
        if ($svcStatus -ne 'Running' -and (Get-Service -Name $ServiceName).Status -eq 'Running') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
    }
    foreach ($e in @(Get-RunEntries)) {
        if ($runBefore -notcontains "$($e.Key)|$($e.Name)") {
            Remove-ItemProperty -LiteralPath $e.Key -Name $e.Name -ErrorAction SilentlyContinue
            Write-Host "[rustdesk] Removed the startup entry the installer added ($($e.Name))."
        }
    }
    foreach ($proc in @(Get-RustDeskProcesses)) {
        if ($procBefore -notcontains $proc.ProcessId -and $procBefore.Count -eq 0) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
