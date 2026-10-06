BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # Runs a step in Windows PowerShell 5.1 with LOCALAPPDATA/APPDATA/USERPROFILE
    # pointed at a scratch folder and $Prelude defining fake commands.
    function Invoke-Step {
        param([string]$Script, [string]$Arguments = '', [string]$Prelude = '', [scriptblock]$Arrange = {})
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\$Script", "$repoRoot\steps\Deelevate.ps1" $case
        & $Arrange $case
        $wrapper = @"
`$env:LOCALAPPDATA = '$case'
`$env:APPDATA = '$case\Roaming'
`$env:USERPROFILE = '$case\Home'
function Test-Elevated { `$false }
$Prelude
& '$case\$Script' $Arguments
exit `$LASTEXITCODE
"@
        Set-Content "$case\wrapper.ps1" $wrapper
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\wrapper.ps1" *> "$case\output.txt"
        [pscustomobject]@{ Code = $LASTEXITCODE; Case = $case; Output = (Get-Content "$case\output.txt" -Raw)
            Calls = $(if (Test-Path "$case\calls.txt") { Get-Content "$case\calls.txt" -Raw } else { '' }) }
    }
}

Describe 'End-of-run manual update list' {
    It 'prints every recorded app with its reason and fix' {
        $r = Invoke-Step -Script 'Show-ManualUpdates.ps1' -Arrange {
            param($case)
            New-Item "$case\Upkeep\Reports" -ItemType Directory -Force | Out-Null
            '[{"Source":"winget","Id":"LizardByte.Sunshine","Name":"Sunshine","Current":"1","Available":"2","Reason":"the new version uses a different installer type","Fix":"reinstall"}]' |
                Set-Content "$case\Upkeep\Reports\manual-updates-winget.json"
            '[{"Source":"choco","Id":"git.install","Name":"Git for Windows","Current":"2.55","Available":"2.56","Reason":"Git is in use","Fix":"close it"}]' |
                Set-Content "$case\Upkeep\Reports\manual-updates-choco.json"
        }
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Needs a manual update \(2\)'
        $r.Output | Should -Match 'Sunshine \[LizardByte.Sunshine\] 1 -> 2'
        $r.Output | Should -Match 'Why: Git is in use'
    }
    It 'limits the list to the requested sources' {
        $r = Invoke-Step -Script 'Show-ManualUpdates.ps1' -Arguments '-Source winget' -Arrange {
            param($case)
            New-Item "$case\Upkeep\Reports" -ItemType Directory -Force | Out-Null
            '[{"Source":"choco","Id":"git.install","Name":"Git for Windows","Reason":"in use","Fix":"close it"}]' |
                Set-Content "$case\Upkeep\Reports\manual-updates-choco.json"
        }
        $r.Output | Should -Not -Match 'Needs a manual update'
    }
}

Describe 'Holding back Git while it is in use' {
    BeforeAll {
        $fakeChoco = @'
function choco {
    Add-Content "$env:LOCALAPPDATA\calls.txt" ($args -join ' ')
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'outdated') { 'git.install|2.55.0|2.56.0|false'; 'git|2.55.0|2.56.0|false' }
}
function Get-ItemProperty { [pscustomobject]@{ InstallPath = 'C:\Program Files\Git' } }
'@
    }
    It 'pins Git for this run, names the processes and records it' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Hold' -Prelude ($fakeChoco + @'

function Get-CimInstance { @([pscustomobject]@{ Name = 'bash.exe'; ProcessId = 41; ExecutablePath = 'C:\Program Files\Git\usr\bin\bash.exe' }) }
'@)
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'pin add -n=git.install'
        $r.Output | Should -Match 'in use by bash.exe \(PID 41\)'
        $report = Get-Content "$($r.Case)\Upkeep\Reports\manual-updates-choco.json" -Raw | ConvertFrom-Json
        $report.Id | Should -Be 'git.install'
        Test-Path "$($r.Case)\Upkeep\choco-held-pins.json" | Should -BeTrue
    }
    It 'leaves Git alone when nothing is using it' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Hold' -Prelude ($fakeChoco + @'

function Get-CimInstance { @([pscustomobject]@{ Name = 'code.exe'; ProcessId = 7; ExecutablePath = 'C:\Apps\code.exe' }) }
'@)
        $r.Calls | Should -Not -Match 'pin add'
        Test-Path "$($r.Case)\Upkeep\Reports\manual-updates-choco.json" | Should -BeFalse
    }
    It 'releases only the pins it added' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Release' -Prelude $fakeChoco -Arrange {
            param($case)
            New-Item "$case\Upkeep" -ItemType Directory -Force | Out-Null
            '["git.install"]' | Set-Content "$case\Upkeep\choco-held-pins.json"
        }
        $r.Calls | Should -Match 'pin remove -n=git.install'
        $r.Calls | Should -Not -Match 'pin remove -n=git '
        Test-Path "$($r.Case)\Upkeep\choco-held-pins.json" | Should -BeFalse
    }
}

Describe 'Claude Code and Codex updates by install method' {
    BeforeAll {
        # Fake npm: `root -g` points at the scratch prefix, `install -g` bumps the version.
        $fakeNpm = @'
function npm {
    Add-Content "$env:LOCALAPPDATA\calls.txt" ($args -join ' ')
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'root') { "$env:APPDATA\npm\node_modules"; return }
    if ($args[0] -eq 'install') {
        if ($env:FAKE_NPM_FAIL -eq '1') { $global:LASTEXITCODE = 1; 'npm ERR! code EBUSY'; return }
        $pkg = ($args[2] -replace '@latest$', '')
        Set-Content "$env:APPDATA\npm\node_modules\$pkg\package.json" '{"version":"9.9.9"}'
    }
}
'@
        $arrangeNpm = {
            param($case)
            New-Item "$case\Roaming\npm\node_modules\@anthropic-ai\claude-code" -ItemType Directory -Force | Out-Null
            '{"version":"1.0.0"}' | Set-Content "$case\Roaming\npm\node_modules\@anthropic-ai\claude-code\package.json"
        }
    }
    It 'updates an npm install through npm' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude $fakeNpm -Arrange $arrangeNpm
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'install -g @anthropic-ai/claude-code@latest'
        $r.Calls | Should -Not -Match '@openai/codex'
        $r.Output | Should -Match 'Claude Code \(npm\): updated 1.0.0 -> 9.9.9'
    }
    It 'lists a failed update for a manual update instead of an error' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude ("`$env:FAKE_NPM_FAIL = '1'`n" + $fakeNpm) -Arrange $arrangeNpm
        $r.Code | Should -Be 3
        $report = Get-Content "$($r.Case)\Upkeep\Reports\manual-updates-cli.json" -Raw | ConvertFrom-Json
        $report.Fix | Should -Match 'npm install -g @anthropic-ai/claude-code@latest'
    }
    It 'reports nothing to do when neither tool is installed this way' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude $fakeNpm
        $r.Code | Should -Be 2
    }
}
