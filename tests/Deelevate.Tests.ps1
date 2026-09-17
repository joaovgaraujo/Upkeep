BeforeAll {
    . "$PSScriptRoot\..\steps\Deelevate.ps1"
    $script:fixtureAction = New-ScheduledTaskAction -Execute 'powershell.exe'
    $script:fixturePrincipal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -LogonType Interactive -RunLevel Limited
    $script:fixtureSettings = New-ScheduledTaskSettingsSet
}
Describe 'Normal-user installer retries' {
    It 'recognizes both WinGet elevation refusals independent of language' {
        Test-RequiresNormalUser -1978335107 'texto localizado' | Should -BeTrue
        Test-RequiresNormalUser -1978335146 'texto localizado' | Should -BeTrue
        Test-RequiresNormalUser -1978335207 'requires admin' | Should -BeFalse
        Test-RequiresNormalUser 1603 'installer failed' | Should -BeFalse
    }
    BeforeEach {
        $script:savedTemp = $env:TEMP
        $env:TEMP = Join-Path $TestDrive "user's temp"
        New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
        Mock Get-DeelevatedUserSid { 'S-1-5-21-123' }
        Mock New-ScheduledTaskAction {
            $script:runner = [regex]::Match($Argument, '-File "([^"]+)"').Groups[1].Value
            $script:fixtureAction
        }
        Mock New-ScheduledTaskPrincipal { $script:fixturePrincipal }
        Mock New-ScheduledTaskSettingsSet { $script:fixtureSettings }
        Mock Register-ScheduledTask {}
        Mock Unregister-ScheduledTask {}
        Mock Start-ScheduledTask {
            Set-Content (Join-Path (Split-Path $script:runner) 'done.txt') '0'
            Set-Content (Join-Path (Split-Path $script:runner) 'out.txt') 'fixture updated'
        }
    }
    AfterEach { $env:TEMP = $script:savedTemp }
    It 'captures confirmed success and removes completed worker files' {
        $r = Invoke-Deelevated -Command 'exit 0'
        $r.Status | Should -Be Completed
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'fixture updated'
        Test-Path (Split-Path $script:runner) | Should -BeFalse
        Should -Invoke New-ScheduledTaskPrincipal -ParameterFilter { $RunLevel -eq 'Limited' -and $UserId -eq 'S-1-5-21-123' }
    }
    It 'does not delete or rerun a worker that may still be installing' {
        Mock Start-ScheduledTask {}
        $r = Invoke-Deelevated -Command 'exit 0' -TimeoutSec 0
        $r.Status | Should -Be TimedOut
        $r.Output | Should -Match 'may still be running'
        Test-Path $script:runner | Should -BeTrue
        Should -Invoke Unregister-ScheduledTask -Times 0
    }
    It 'does not treat an invalid completion code as success' {
        Mock Start-ScheduledTask { Set-Content (Join-Path (Split-Path $script:runner) 'done.txt') 'bad' }
        $r = Invoke-Deelevated -Command 'exit 0'
        $r.Status | Should -Be Unavailable
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'invalid exit code'
    }
    It 'reports another-account or missing desktop session before launching' {
        Mock Get-DeelevatedUserSid { throw 'No desktop session for this account' }
        $r = Invoke-Deelevated -Command 'exit 0'
        $r.Status | Should -Be Unavailable
        $r.Output | Should -Match 'No desktop session'
        Should -Invoke Start-ScheduledTask -Times 0
    }
    It 'generates valid PowerShell with an elevation check in apostrophe paths' {
        Mock Start-ScheduledTask {}
        $null = Invoke-Deelevated -Command 'winget --version' -TimeoutSec 0
        $parseTokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:runner, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
        $parseErrors.Count | Should -Be 0
        Get-Content $script:runner -Raw | Should -Match 'Installer was not started'
    }
}
