BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # Runs Move-PowerShellToMsix.ps1 against a fake uninstall key, OpenSSH key,
    # winget, Appx cmdlets and msiexec. Returns the result object and the calls.
    function Invoke-FakeMove {
        param([switch]$NoMsi, [switch]$SshdUsesIt, [switch]$MsixPresent, [switch]$DownloadFails, [int]$MsiExit = 0)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        $root = "HKCU:\Software\UpkeepTest\$(Split-Path $case -Leaf)"
        $code = '{11111111-2222-3333-4444-555555555555}'
        New-Item "$root\Uninstall\$code" -Force | Out-Null
        New-Item "$root\OpenSSH" -Force | Out-Null
        $folder = Join-Path $case 'PowerShell\7'
        if (-not $NoMsi) {
            Set-ItemProperty "$root\Uninstall\$code" -Name DisplayName -Value 'PowerShell 7-x64'
            Set-ItemProperty "$root\Uninstall\$code" -Name DisplayVersion -Value '7.6.10.0'
            Set-ItemProperty "$root\Uninstall\$code" -Name InstallLocation -Value "$folder\"
            New-ItemProperty "$root\Uninstall\$code" -Name WindowsInstaller -Value 1 -PropertyType DWord | Out-Null
        }
        if ($SshdUsesIt) { Set-ItemProperty "$root\OpenSSH" -Name DefaultShell -Value "$folder\pwsh.exe" }
        $regPath = ($root -replace '^HKCU:', 'HKCU') + "\Uninstall\$code"
        Set-Content "$case\msiexec.cmd" "@echo %* >> `"$case\calls.txt`"`r`n@if $MsiExit==0 reg delete `"$regPath`" /f >nul`r`n@exit /b $MsiExit"
        $wrapper = @"
`$global:msix = `$$([bool]$MsixPresent)
function winget {
    Add-Content '$case\calls.txt' ('winget ' + (`$args -join ' '))
    if (`$$([bool]$DownloadFails)) { 'Download failed'; return }
    `$dir = `$args[`$args.IndexOf('--download-directory') + 1]
    New-Item `$dir -ItemType Directory -Force | Out-Null
    Set-Content "`$dir\PowerShell-7.7.0.msixbundle" 'fixture'
}
function Get-AppxPackage { if (`$global:msix) { [pscustomobject]@{ Name = 'Microsoft.PowerShell'; Version = '7.7.0.0' } } }
function Add-AppxPackage { param(`$Path) Add-Content '$case\calls.txt' "ADD `$Path"; `$global:msix = `$true }
`$r = & '$repoRoot\steps\Move-PowerShellToMsix.ps1' -UninstallPaths '$root\Uninstall\*' -SshdKey '$root\OpenSSH' -MsiExec '$case\msiexec.cmd' -WorkDir '$case\work'
`$r | ConvertTo-Json -Compress | Set-Content '$case\result.json'
"@
        Set-Content "$case\wrapper.ps1" $wrapper
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\wrapper.ps1" *> "$case\output.txt"
        $msiLeft = Test-Path "$root\Uninstall\$code"
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Result = $(if (Test-Path "$case\result.json") { Get-Content "$case\result.json" -Raw | ConvertFrom-Json })
            Calls = "$(Get-Content "$case\calls.txt" -Raw -ErrorAction SilentlyContinue)"
            Output = (Get-Content "$case\output.txt" -Raw)
            MsiLeft = $msiLeft
        }
    }
}
AfterAll { Remove-Item 'HKCU:\Software\UpkeepTest' -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Moving PowerShell 7 from the MSI to the MSIX package' {
    It 'installs the MSIX first, then removes the MSI' {
        $r = Invoke-FakeMove
        $r.Result.Status | Should -Be 'moved'
        $r.Calls | Should -Match 'winget download --id Microsoft.PowerShell --exact'
        $r.Calls | Should -Match 'ADD .*PowerShell-7\.7\.0\.msixbundle'
        $r.Calls | Should -Match '/x \{11111111-2222-3333-4444-555555555555\} /qn /norestart'
        ($r.Calls.IndexOf('ADD ')) | Should -BeLessThan ($r.Calls.IndexOf('/x '))
        $r.MsiLeft | Should -BeFalse
    }
    It 'does nothing without an MSI install' {
        $r = Invoke-FakeMove -NoMsi
        $r.Result.Status | Should -Be 'skip'
        $r.Calls | Should -BeNullOrEmpty
    }
    It 'keeps the MSI when OpenSSH uses it as its default shell' {
        $r = Invoke-FakeMove -SshdUsesIt
        $r.Result.Status | Should -Be 'manual'
        $r.Result.Reason | Should -Match 'OpenSSH'
        $r.Calls | Should -BeNullOrEmpty
        $r.MsiLeft | Should -BeTrue
    }
    It 'only removes the MSI when the MSIX is already installed' {
        $r = Invoke-FakeMove -MsixPresent
        $r.Result.Status | Should -Be 'moved'
        $r.Calls | Should -Not -Match 'winget download'
        $r.MsiLeft | Should -BeFalse
    }
    It 'keeps the MSI when the MSIX download fails' {
        $r = Invoke-FakeMove -DownloadFails
        $r.Result.Status | Should -Be 'failed'
        $r.Calls | Should -Not -Match '/x '
        $r.MsiLeft | Should -BeTrue
    }
    It 'reports a failed MSI removal' {
        $r = Invoke-FakeMove -MsiExit 1603
        $r.Result.Status | Should -Be 'failed'
        $r.Result.Detail | Should -Match '1603'
    }
}
