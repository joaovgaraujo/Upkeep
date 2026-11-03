BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # Runs a step in Windows PowerShell 5.1 with LOCALAPPDATA/APPDATA/USERPROFILE
    # pointed at a scratch folder and $Prelude defining fake commands.
    function Invoke-Step {
        param([string]$Script, [string]$Arguments = '', [string]$Prelude = '', [scriptblock]$Arrange = {})
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\$Script", "$repoRoot\steps\Deelevate.ps1", "$repoRoot\steps\InUse.ps1" $case
        # Steps dot-source Deelevate.ps1, which would redefine Test-Elevated after
        # the prelude. CI runners are elevated, so override it in the copy itself.
        Add-Content "$case\Deelevate.ps1" 'function Test-Elevated { $false }'
        & $Arrange $case
        $wrapper = @"
`$env:LOCALAPPDATA = '$case'
`$env:APPDATA = '$case\Roaming'
`$env:USERPROFILE = '$case\Home'
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
    It 'prints each entry of one report on its own line' {
        $r = Invoke-Step -Script 'Show-ManualUpdates.ps1' -Arrange {
            param($case)
            New-Item "$case\Upkeep\Reports" -ItemType Directory -Force | Out-Null
            '[{"Source":"winget","Id":"Logitech.GHUB","Name":"Logitech G HUB","Current":"1","Available":"2","Reason":"reports success","Fix":"open it"},{"Source":"winget","Id":"Git.Git","Name":"Git","Current":"3","Available":"4","Reason":"Git is in use","Fix":"close it"}]' |
                Set-Content "$case\Upkeep\Reports\manual-updates-winget.json"
        }
        $r.Output | Should -Match 'Needs a manual update \(2\)'
        $r.Output | Should -Match 'Logitech G HUB \[Logitech.GHUB\] 1 -> 2'
        $r.Output | Should -Match 'Git \[Git.Git\] 3 -> 4'
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
# The real uv and its live processes must not leak into these tests.
function uv { Add-Content "$env:LOCALAPPDATA\calls.txt" ('uv ' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
function Get-Process { if ($env:FAKE_UV_RUNNING -eq '1') { @([pscustomobject]@{ Name = 'uv' }, [pscustomobject]@{ Name = 'uv' }) } }
'@
    }
    It 'pins Git for this run, names the processes and records it' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Hold' -Prelude ($fakeChoco + @'

function Get-CimInstance { @([pscustomobject]@{ Name = 'bash.exe'; ProcessId = 41; ExecutablePath = 'C:\Program Files\Git\usr\bin\bash.exe' }) }
'@)
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'pin add -n=git.install'
        $r.Output | Should -Match 'in use by bash.exe - holding it back'
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
    It 'skips topgrade''s uv step and upgrades uv tools directly while uv processes run' {
        $prelude = "`$env:FAKE_UV_RUNNING = '1'`n" + $fakeChoco + "`nfunction Get-CimInstance { @() }`n"
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Hold' -Prelude $prelude
        $r.Code | Should -Be 0
        Get-Content "$($r.Case)\SystemUpdate\topgrade-extra-args.txt" | Should -Be '--disable uv'
        $r.Calls | Should -Match 'uv tool upgrade --all'
        $r.Output | Should -Match 'uv x2 running'
    }
    It 'leaves topgrade''s uv step alone when no uv process runs' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Hold' -Prelude ($fakeChoco + "`nfunction Get-CimInstance { @() }`n")
        Test-Path "$($r.Case)\SystemUpdate\topgrade-extra-args.txt" | Should -BeFalse
        $r.Calls | Should -Not -Match 'uv tool'
    }
    It 'removes the extra topgrade arguments on release' {
        $r = Invoke-Step -Script 'Protect-InUsePackages.ps1' -Arguments '-Action Release' -Prelude $fakeChoco -Arrange {
            param($case)
            New-Item "$case\SystemUpdate" -ItemType Directory -Force | Out-Null
            '--disable uv' | Set-Content "$case\SystemUpdate\topgrade-extra-args.txt"
        }
        Test-Path "$($r.Case)\SystemUpdate\topgrade-extra-args.txt" | Should -BeFalse
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

Describe 'Moving Claude Code to another install method' {
    BeforeAll {
        # Fake npm and winget. winget lists Claude Code at 2.1.302 until
        # `winget uninstall` runs; npm offers 2.1.317.
        $fakes = @'
function npm {
    Add-Content "$env:LOCALAPPDATA\calls.txt" ("npm " + ($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'root') { "$env:APPDATA\npm\node_modules"; return }
    if ($args[0] -eq 'view') { '2.1.317'; return }
    if ($args[0] -eq 'install') {
        if ($env:FAKE_NPM_FAIL -eq '1') { $global:LASTEXITCODE = 1; 'npm ERR! code EBUSY'; return }
        New-Item "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code" -ItemType Directory -Force | Out-Null
        Set-Content "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code\package.json" '{"version":"2.1.317"}'
    }
}
function winget {
    Add-Content "$env:LOCALAPPDATA\calls.txt" ("winget " + ($args -join ' '))
    $global:LASTEXITCODE = 0
    $gone = Test-Path "$env:LOCALAPPDATA\winget-removed"
    if ($args[0] -eq 'uninstall') { New-Item "$env:LOCALAPPDATA\winget-removed" -ItemType File | Out-Null; 'Successfully uninstalled'; return }
    if ($args[0] -eq 'show') { 'Found Claude Code [Anthropic.ClaudeCode]'; 'Version: 2.1.302'; 'Publisher: Anthropic PBC'; return }
    if ($args[0] -eq 'list') {
        if ($args -notcontains 'Anthropic.ClaudeCode' -or $gone) { $global:LASTEXITCODE = -1978335212; 'No installed package found'; return }
        'Name          Id                    Version  Source'
        '-----------------------------------------------------'
        'Claude Code   Anthropic.ClaudeCode  2.1.302  winget'
    }
}
'@
        $settings = {
            param($case)
            '{"AiCliChannels":{"claude-code":"npm"}}' | Set-Content "$case\settings.json"
        }
    }
    It 'installs through npm first, then removes the winget install' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude $fakes -Arrange $settings -Arguments '-SettingsPath "$env:LOCALAPPDATA\settings.json"'
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'switching from winget 2.1.302 to npm'
        $r.Output | Should -Match 'winget install removed'
        $calls = $r.Calls -split "`r?`n"
        $install = [array]::IndexOf($calls, ($calls | Where-Object { $_ -match 'npm install -g @anthropic-ai/claude-code@latest' } | Select-Object -First 1))
        $remove = [array]::IndexOf($calls, ($calls | Where-Object { $_ -match 'winget uninstall --id Anthropic.ClaudeCode' } | Select-Object -First 1))
        $install | Should -BeGreaterOrEqual 0
        $remove | Should -BeGreaterThan $install
    }
    It 'keeps the winget install when the npm install fails' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude ("`$env:FAKE_NPM_FAIL = '1'`n" + $fakes) -Arrange $settings -Arguments '-SettingsPath "$env:LOCALAPPDATA\settings.json"'
        $r.Code | Should -Be 3
        $r.Calls | Should -Not -Match 'winget uninstall'
        $report = Get-Content "$($r.Case)\Upkeep\Reports\manual-updates-cli.json" -Raw | ConvertFrom-Json
        $report.Reason | Should -Match 'switch to npm failed.*current install was kept'
    }
    It 'reports each install method and what the others offer' {
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude $fakes -Arrange $settings -Arguments '-Detect -SettingsPath "$env:LOCALAPPDATA\settings.json"'
        $r.Code | Should -Be 0
        $json = @($r.Output | ConvertFrom-Json)
        $json[0].Key | Should -Be 'claude-code'
        $json[0].Installs[0].Method | Should -Be 'winget'
        $json[0].Installs[0].Version | Should -Be '2.1.302'
        $json[0].Latest.npm | Should -Be '2.1.317'
        $json[0].Latest.winget | Should -Be '2.1.302'
        $json[0].Preferred | Should -Be 'npm'
        $r.Calls | Should -Not -Match 'install|uninstall'
    }
    It 'starts with -File and no settings path, as the engine and the dashboard run it' {
        # 1.8.6 put $PSScriptRoot in a param() default; Windows PowerShell 5.1
        # leaves it empty there under -File, so every real run failed.
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item "$case\steps" -ItemType Directory -Force | Out-Null
        Copy-Item "$repoRoot\steps\Update-AiClis.ps1", "$repoRoot\steps\Deelevate.ps1" "$case\steps"
        '{"AiCliChannels":{}}' | Set-Content "$case\settings.json"
        $old = $env:PATH, $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE
        try {
            # No npm or winget on PATH, so nothing is queried or installed.
            $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
            $env:LOCALAPPDATA = $case; $env:APPDATA = "$case\Roaming"; $env:USERPROFILE = "$case\Home"
            $detect = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\steps\Update-AiClis.ps1" -Detect 2>&1 | Out-String
            $detectCode = $LASTEXITCODE
            $run = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\steps\Update-AiClis.ps1" 2>&1 | Out-String
            $runCode = $LASTEXITCODE
        } finally { $env:PATH, $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE = $old }
        $detectCode | Should -Be 0
        $detect.Trim() | Should -Be '[]'
        $runCode | Should -Be 2
        $run | Should -Not -Match 'Cannot bind argument'
    }
    It 'only switches, and reports skipped, when other updaters are off' {
        $prelude = "`$env:DASHBOARD_SKIP_OTHER_APPS = '1'`n" + $fakes
        $r = Invoke-Step -Script 'Update-AiClis.ps1' -Prelude $prelude -Arguments '-SettingsPath "$env:LOCALAPPDATA\settings.json"' -Arrange {
            param($case)
            '{"AiCliChannels":{"claude-code":""}}' | Set-Content "$case\settings.json"
        }
        $r.Code | Should -Be 4
        $r.Calls | Should -Not -Match 'npm install|winget (un)?install'
    }
}
