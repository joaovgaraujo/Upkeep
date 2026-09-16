param([Parameter(Mandatory)][string]$Backup)
$ErrorActionPreference = 'Stop'
$failed = 0
$entries = @((Get-Content -LiteralPath $Backup -Raw | ConvertFrom-Json))
[array]::Reverse($entries)
foreach ($entry in $entries) {
    try {
        if ($entry.Exists) {
            if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
            Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.Type
        } else {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
        }
        Write-Output "Restored $($entry.Path) / $($entry.Name)"
    } catch { $failed++; Write-Warning $_ }
}
if ($failed) { exit 1 }
