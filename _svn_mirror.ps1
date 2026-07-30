# Mirrors Snappy Driver Installer Origin's SVN trunk for reading. SDIO is the
# driver tool Upkeep shells out to (Tools page and Setup-NewPC.ps1).
#
# TWO THINGS TO KNOW BEFORE RUNNING THIS:
#
# 1. The default URL used to point at `snappy-driver-installer`, which is the
#    ORIGINAL Snappy Driver Installer, not Origin -- a different project whose
#    binary releases stopped in 2017. SDIO is `snappy-driver-installer-origin`.
#    The destination folder was already named "SDIO-source", so the mismatch
#    was silently mirroring the wrong codebase.
#
# 2. SDIO is GPL-3.0-or-later. Upkeep is MIT. Shelling out to SDIO as a
#    separate process creates NO licence obligation, which is why the
#    integration is fine -- but a mirrored source tree is GPL code sitting in
#    an MIT repository. `vendor/` is gitignored and `git ls-files vendor`
#    returns nothing; KEEP IT THAT WAY. Committing this output, or bundling
#    SDIO into a release artifact, would be conveying under GPLv3 section 6
#    and would oblige you to ship corresponding source. Install it with
#    `winget install --id GlennDelahoy.SnappyDriverInstallerOrigin` instead.
param(
    [string]$BaseUrl = "https://svn.code.sf.net/p/snappy-driver-installer-origin/code/trunk/",
    [string]$Dest = "$PSScriptRoot\vendor\SDIO-Origin-source"
)

function Mirror-Dir {
    param([string]$Url, [string]$LocalPath)
    if (-not (Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Host "FAILED listing: $Url - $($_.Exception.Message)"
        return
    }
    $links = [regex]::Matches($resp.Content, '<a href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value }
    foreach ($link in $links) {
        if ($link -eq "../") { continue }
        $decoded = [System.Uri]::UnescapeDataString($link)
        $childUrl = $Url + $link
        $childLocal = Join-Path $LocalPath $decoded.TrimEnd('/')
        if ($link.EndsWith('/')) {
            Mirror-Dir -Url $childUrl -LocalPath $childLocal
        } else {
            try {
                Invoke-WebRequest -Uri $childUrl -OutFile $childLocal -UseBasicParsing -TimeoutSec 60
                Write-Host "OK: $childLocal"
            } catch {
                Write-Host "FAILED file: $childUrl - $($_.Exception.Message)"
            }
        }
    }
}

Mirror-Dir -Url $BaseUrl -LocalPath $Dest
Write-Host "DONE"
