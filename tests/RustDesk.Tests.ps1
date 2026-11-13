BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # A fake install (an uninstall key under HKCU) and a fake GitHub release
    # (a JSON file read through file://). Nothing is downloaded or installed.
    function Invoke-RustDeskStep {
        param([string]$Installed, [string]$Latest = '1.5.3', [switch]$Choco, [switch]$NoAsset)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $case -ItemType Directory | Out-Null
        $key = "HKCU:\Software\UpkeepTest\Uninstall_$([guid]::NewGuid().ToString('N'))"
        if ($Installed) {
            New-Item $key -Force | Out-Null
            New-ItemProperty $key -Name DisplayVersion -Value $Installed | Out-Null
            New-ItemProperty $key -Name InstallLocation -Value "$case\RustDesk" | Out-Null
            New-ItemProperty $key -Name WindowsInstaller -Value 0 -PropertyType DWord | Out-Null
        }
        $name = if ($NoAsset) { "rustdesk-$Latest-x86_64.deb" } else { "rustdesk-$Latest-x86_64.exe" }
        @{ tag_name = $Latest; assets = @(@{ name = $name; size = 1000; browser_download_url = 'https://example.invalid/x' }) } |
            ConvertTo-Json -Depth 4 | Set-Content "$case\release.json"
        $lib = "$case\choco\lib\rustdesk"
        if ($Choco) { New-Item $lib -ItemType Directory -Force | Out-Null }
        try {
            $out = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$repoRoot\steps\Update-RustDesk.ps1" `
                -UninstallKey $key -ReleaseApi ([uri]"$case\release.json").AbsoluteUri -ChocoLib $lib `
                -ReportDir "$case\Reports" -CheckOnly 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally { Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue }
        [pscustomobject]@{ Code = $code; Output = $out }
    }
}
AfterAll { Remove-Item 'HKCU:\Software\UpkeepTest' -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'RustDesk updater (fake install and release)' {
    It 'skips when RustDesk is not installed' {
        $r = Invoke-RustDeskStep
        $r.Code | Should -Be 2
        $r.Output | Should -Match 'not installed'
    }
    It 'leaves a Chocolatey install to Chocolatey' {
        $r = Invoke-RustDeskStep -Installed '1.5.1' -Choco
        $r.Code | Should -Be 2
        $r.Output | Should -Match 'Chocolatey'
    }
    It 'reports current when the release is not newer' {
        $r = Invoke-RustDeskStep -Installed '1.5.3'
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Already current \(1\.5\.3\)'
    }
    It 'picks the installer of the installed kind for a newer release' {
        $r = Invoke-RustDeskStep -Installed '1.5.1' -Latest '1.5.3'
        $r.Code | Should -Be 0
        $r.Output | Should -Match '1\.5\.1 -> 1\.5\.3 available'
        $r.Output | Should -Match 'Would install rustdesk-1\.5\.3-x86_64\.exe'
    }
    It 'skips when the release has no Windows installer of that kind' {
        $r = Invoke-RustDeskStep -Installed '1.5.1' -NoAsset
        $r.Code | Should -Be 2
        $r.Output | Should -Match 'no x86_64 \.exe installer'
    }
}
