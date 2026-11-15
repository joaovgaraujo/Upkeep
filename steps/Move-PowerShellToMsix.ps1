<#
.SYNOPSIS
    Moves PowerShell 7 from its MSI install to the MSIX package winget now
    ships, so it can keep updating.

.DESCRIPTION
    winget ships PowerShell 7.7 only as an MSIX package. `winget upgrade` can't
    turn the 7.6 MSI install into it and fails with "No installed package found
    matching input criteria" (0x8A150014, 2026-11-15). Doing the move by hand
    worked: install the MSIX, then remove the MSI.

    This step does the same, in an order that never leaves the PC without
    PowerShell 7:
      1. Find the MSI install. None: nothing to do.
      2. Leave it alone when OpenSSH uses it as its default shell, or when
         PowerShell 7 windows from it are open (the uninstall would need a
         restart). Both are reported as a manual update.
      3. Download the MSIX with winget (winget checks the hash) and add it for
         this user, unless the MSIX is already there.
      4. Only once the MSIX is installed, remove the MSI with msiexec.

    Writes one object: Status ('moved', 'manual', 'skip' or 'failed'), with a
    Reason and Fix for 'manual' and a Detail for 'failed'.
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    # Tests point these at fixtures.
    [string[]]$UninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'),
    [string]$SshdKey = 'HKLM:\SOFTWARE\OpenSSH',
    [string]$MsiExec = 'msiexec.exe',
    [string]$WorkDir = (Join-Path $env:TEMP 'Upkeep-pwsh-msix')
)

function Write-Log {
    param([string]$Text)
    if ($LogFile -and $Text) { try { $Text | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
}
function Result {
    param([string]$Status, [string]$Reason, [string]$Fix, [string]$Detail)
    [pscustomobject]@{ Status = $Status; Reason = $Reason; Fix = $Fix; Detail = $Detail }
}

$msi = Get-ItemProperty $UninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^PowerShell 7' -and $_.WindowsInstaller -eq 1 } |
    Select-Object -First 1
if (-not $msi) { return (Result skip) }
$productCode = $msi.PSChildName
$folder = "$($msi.InstallLocation)".TrimEnd('\')
if (-not $folder) { $folder = Join-Path $env:ProgramFiles 'PowerShell\7' }
$prefix = "$folder\"

$shell = (Get-ItemProperty -LiteralPath $SshdKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($shell -and $shell.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    return (Result manual -Reason "OpenSSH uses PowerShell 7 from $folder as its default shell, and winget only ships 7.7 as an MSIX package" `
        -Fix "Point OpenSSH's DefaultShell (HKLM\SOFTWARE\OpenSSH) at another shell, then run Upkeep again; it moves PowerShell to the MSIX package.")
}

$open = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
if ($open.Count) {
    $names = ($open | Group-Object ProcessName | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    return (Result manual -Reason "PowerShell 7 is open ($names), and moving it to the MSIX package removes the old install" `
        -Fix 'Close PowerShell 7 windows and terminal tabs, then run Upkeep again.')
}

$appx = Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
if (-not $appx) {
    Write-Host "[winget]   Microsoft.PowerShell : winget only ships 7.7 as an MSIX package; installing it, then removing the $($msi.DisplayVersion) MSI..."
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    $out = winget download --id Microsoft.PowerShell --exact --download-directory $WorkDir `
        --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-String
    Write-Log $out
    $bundle = Get-ChildItem -LiteralPath $WorkDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msixbundle', '.msix' } | Select-Object -First 1
    if (-not $bundle) {
        return (Result failed -Detail "winget download did not produce an MSIX package: $(($out -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))")
    }
    try { Add-AppxPackage -Path $bundle.FullName -ErrorAction Stop }
    catch { return (Result failed -Detail "Add-AppxPackage failed: $($_.Exception.Message)") }
    finally { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    $appx = Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $appx) { return (Result failed -Detail 'the MSIX package is not installed after Add-AppxPackage; the MSI was kept.') }
}
Write-Host "[winget]   Microsoft.PowerShell : MSIX $($appx.Version) installed; removing the $($msi.DisplayVersion) MSI..."

$p = Start-Process -FilePath $MsiExec -ArgumentList @('/x', $productCode, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
$code = $p.ExitCode
# 3010: removed, a restart finishes it.
if ($code -notin 0, 3010) {
    return (Result failed -Detail "MSIX $($appx.Version) is installed, but removing the MSI ($productCode) failed with msiexec exit $code.")
}
$left = Get-ItemProperty $UninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq $productCode }
if ($left) {
    return (Result failed -Detail "MSIX $($appx.Version) is installed, but the MSI ($productCode) is still registered after msiexec.")
}
Write-Host "[winget]   Microsoft.PowerShell : moved to the MSIX package ($($appx.Version)); the MSI is removed."
Result moved
