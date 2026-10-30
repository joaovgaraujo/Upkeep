# Helpers for "is this program in use right now?", dot-sourced by the steps
# that hold an update back instead of letting its installer abort.

# Git for Windows' install folder (registry first, default location second).
function Get-GitInstallDir {
    $dir = (Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction SilentlyContinue).InstallPath
    if (-not $dir) { $dir = Join-Path $env:ProgramFiles 'Git' }
    $dir
}

# Processes whose executable lives under $Folder. Callers wrap the call in
# @(): PowerShell 5.1 unrolls a one-element array to a single object, whose
# .Count is $null there, so exactly one process would read as none.
function Get-FolderProcesses {
    param([Parameter(Mandatory)][string]$Folder)
    $prefix = $Folder.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# "bash.exe x42, sleep.exe x10, ssh.exe". Listing every PID made one log line
# run to 120 entries when terminals had left Git Bash helpers behind.
function Format-ProcessCounts {
    param($Processes)
    (@($Processes) | Group-Object Name | Sort-Object Count -Descending |
        ForEach-Object { if ($_.Count -gt 1) { "$($_.Name) x$($_.Count)" } else { $_.Name } }) -join ', '
}
