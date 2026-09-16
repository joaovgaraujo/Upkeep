param([ValidateSet('winget','choco')][string]$Manager)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    if ($Manager -eq 'winget') {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Warning $_ }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
            Install-Module Microsoft.WinGet.Client -Repository PSGallery -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            Repair-WinGetPackageManager -AllUsers -Force -ErrorAction Stop
        }
    } else {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            $installer = Join-Path $env:TEMP ('upkeep-choco-' + [guid]::NewGuid() + '.ps1')
            try {
                Invoke-WebRequest https://community.chocolatey.org/install.ps1 -UseBasicParsing -TimeoutSec 60 -OutFile $installer
                & $installer
            } finally { Remove-Item -LiteralPath $installer -ErrorAction SilentlyContinue }
        }
    }
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
