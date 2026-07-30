param(
    [string]$BaseUrl = "https://svn.code.sf.net/p/snappy-driver-installer/code/trunk/",
    [string]$Dest = "d:\pythonprojects\updateall\vendor\SDIO-source"
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
