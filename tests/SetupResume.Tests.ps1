BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . "$repo\steps\Setup-Resume.ps1"
    function Invoke-ResumeFixture {
        param([string]$Scenario)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$case\steps" -Force | Out-Null
        Copy-Item "$repo\steps\Setup-Resume.ps1", "$repo\steps\Resume-Setup.ps1" "$case\steps"
        $state = @{Version=1;Task='Upkeep-Resume-fixture';BootId='2026-09-15T00:00:00.0000000Z';Status='WaitingForRestart';Apps=@('docker-desktop');Tweaks=@();PreferChoco=$false;Detail='Waiting'}
        if ($Scenario -eq 'same-boot') { $state.BootId = '2026-09-16T00:00:00.0000000Z' }
        if ($Scenario -eq 'completed') { $state.Status = 'Completed' }
        $state | ConvertTo-Json | Set-Content "$case\resume.json"
        $fakeInstaller = @'
param($Apps,$Catalog,[switch]$NoRebootPrompt,$ResultFile,[switch]$PreferChoco)
Add-Content "$PSScriptRoot\calls.txt" ("install " + ($Apps -join ',') + " prompt-disabled=$NoRebootPrompt")
Set-Content -LiteralPath $ResultFile '[{"Slug":"docker-desktop","Status":"Installed","ExitCode":0}]'
exit 0
'@
        Set-Content "$case\Install-Apps.ps1" $fakeInstaller
        $wrapper = @'
$env:LOCALAPPDATA=$PSScriptRoot
function Get-CimInstance { [pscustomobject]@{LastBootUpTime=[datetime]::SpecifyKind([datetime]'2026-09-16',[DateTimeKind]::Utc)} }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm) Add-Content "$PSScriptRoot\calls.txt" "unregister $TaskName" }
function Test-Path {
 param($LiteralPath)
 if ($LiteralPath -like 'HKLM:*') { return ('SCENARIO' -eq 'pending') }
 Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
& "$PSScriptRoot\steps\Resume-Setup.ps1" -StatePath "$PSScriptRoot\resume.json"
exit $LASTEXITCODE
'@
        Set-Content "$case\run.ps1" $wrapper.Replace('SCENARIO',$Scenario)
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-Null
        $calls = if (Test-Path "$case\calls.txt") { Get-Content "$case\calls.txt" -Raw } else { '' }
        [pscustomobject]@{State=(Get-Content "$case\resume.json" -Raw | ConvertFrom-Json);Calls=$calls}
    }
}
Describe 'After-sign-in continuation with fake boots and installers' {
    It 'does nothing after a sign-out without a reboot' {
        $r=Invoke-ResumeFixture same-boot
        $r.State.Status | Should -Be 'WaitingForRestart'
        $r.Calls | Should -Be ''
    }
    It 'consumes the task and installs only the queued apps after a new boot' {
        $r=Invoke-ResumeFixture new-boot
        $r.State.Status | Should -Be 'Completed'
        $r.Calls | Should -Match 'unregister Upkeep-Resume-fixture'
        $r.Calls | Should -Match 'install docker-desktop prompt-disabled=True'
    }
    It 'stops without installing if servicing still requires another restart' {
        $r=Invoke-ResumeFixture pending
        $r.State.Status | Should -Be 'NeedsAttention'
        $r.Calls | Should -Not -Match 'install '
    }
    It 'never repeats a completed continuation' {
        $r=Invoke-ResumeFixture completed
        $r.State.Status | Should -Be 'Completed'
        $r.Calls | Should -Be ''
    }
}
Describe 'Restart approval and durable continuation' {
    BeforeEach {
        $savedProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        Mock Get-SetupRestartChoice { 'Cancel' }
        Mock Invoke-SetupRestart { throw 'Test must never restart the computer' }
        Mock Get-SetupBootId { 'boot-before' }
        Mock Get-ScheduledTask { $null }
        Mock Set-Acl {}
        Mock Register-ScheduledTask {}
    }
    AfterEach { $env:ProgramData = $savedProgramData }
    It 'does not even prompt when no work requires reboot' {
        Request-SetupResume -Root $repo
        Should -Invoke Get-SetupRestartChoice -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
    }
    It 'does not register or reboot when cancelled' {
        Request-SetupResume -Root $repo -Apps docker-desktop
        Should -Invoke Register-ScheduledTask -Times 0
        Should -Invoke Invoke-SetupRestart -Times 0
    }
    It 'saves the exact unfinished list and schedules without rebooting for Later' {
        Mock Get-SetupRestartChoice { 'No' }
        Request-SetupResume -Root $repo -Apps docker-desktop -Tweaks WPFTweaksDiskCleanup
        Should -Invoke Register-ScheduledTask -Times 1
        Should -Invoke Invoke-SetupRestart -Times 0
        $path = Get-ChildItem "$TestDrive\Upkeep-Resume" -Filter resume.json -Recurse | Select-Object -Last 1
        $state = Get-Content $path.FullName -Raw | ConvertFrom-Json
        $state.Apps | Should -Contain 'docker-desktop'
        $state.Tweaks | Should -Contain 'WPFTweaksDiskCleanup'
        $state.BootId | Should -Be 'boot-before'
        Test-Path (Join-Path $path.DirectoryName 'steps\Resume-Setup.ps1') | Should -BeTrue
    }
    It 'only restarts after successful registration and explicit Now' {
        Mock Get-SetupRestartChoice { 'Yes' }
        Mock Invoke-SetupRestart {}
        Request-SetupResume -Root $repo -RestartRequired
        Should -Invoke Register-ScheduledTask -Times 1
        Should -Invoke Invoke-SetupRestart -Times 1
    }
    It 'never reboots if task registration fails' {
        Mock Get-SetupRestartChoice { 'Yes' }
        Mock Register-ScheduledTask { throw 'fixture registration failure' }
        { Request-SetupResume -Root $repo -Apps wsl } | Should -Throw '*registration failure*'
        Should -Invoke Invoke-SetupRestart -Times 0
    }
    It 'refuses duplicate pending continuations' {
        Mock Get-SetupRestartChoice { 'Yes' }
        Mock Get-ScheduledTask { [pscustomobject]@{TaskName='Upkeep-Resume-existing'} }
        { Request-SetupResume -Root $repo -Apps wsl } | Should -Throw '*already scheduled*'
        Should -Invoke Invoke-SetupRestart -Times 0
    }
    It 'queues only restart-blocked apps, never successful, failed or manual-only apps' {
        $items = @(
            [pscustomobject]@{Slug='docker';Status='Deferred';RebootRequired=$true},
            [pscustomobject]@{Slug='done';Status='Installed';RebootRequired=$false},
            [pscustomobject]@{Slug='ea';Status='Deferred'},
            [pscustomobject]@{Slug='failed';Status='Failed'}
        )
        $result = @(Get-RebootApps $items)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 'docker'
    }
}

Describe 'WSL prerequisites with fake Windows servicing' {
    It 'enables missing features without rebooting or starting Docker early' {
        $case=Join-Path $TestDrive 'wsl-features'
        New-Item -ItemType Directory -Path $case | Out-Null
        Copy-Item "$repo\steps\Initialize-WSL.ps1" $case
        $wrapper=@'
function Get-WindowsOptionalFeature { [pscustomobject]@{State='Disabled'} }
function Enable-WindowsOptionalFeature { param($FeatureName,[switch]$Online,[switch]$All,[switch]$NoRestart) Add-Content "$PSScriptRoot\calls.txt" "$FeatureName NoRestart=$NoRestart" }
function wsl.exe { throw 'WSL must not run until Windows features complete their reboot' }
& "$PSScriptRoot\Initialize-WSL.ps1"
exit $LASTEXITCODE
'@
        Set-Content "$case\run.ps1" $wrapper
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-Null
        $LASTEXITCODE | Should -Be 3010
        $calls=Get-Content "$case\calls.txt" -Raw
        $calls | Should -Match 'VirtualMachinePlatform NoRestart=True'
        $calls | Should -Match 'Microsoft-Windows-Subsystem-Linux NoRestart=True'
    }
    It 'installs and verifies the WSL runtime after features are enabled without creating a distro' {
        $case=Join-Path $TestDrive 'wsl-ready'
        New-Item -ItemType Directory -Path $case | Out-Null
        Copy-Item "$repo\steps\Initialize-WSL.ps1" $case
        $wrapper=@'
function Get-WindowsOptionalFeature { [pscustomobject]@{State='Enabled'} }
function Enable-WindowsOptionalFeature { throw 'Already enabled' }
function wsl.exe { Add-Content "$PSScriptRoot\calls.txt" ($args -join ' '); $global:LASTEXITCODE=0 }
& "$PSScriptRoot\Initialize-WSL.ps1"
exit $LASTEXITCODE
'@
        Set-Content "$case\run.ps1" $wrapper
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-Null
        $LASTEXITCODE | Should -Be 0
        $calls=Get-Content "$case\calls.txt" -Raw
        $calls | Should -Match '--install --no-distribution --no-launch'
        $calls | Should -Match '--update --web-download'
        $calls | Should -Match '--version'
    }
}
