BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-InstallFixture {
        param([string]$Scenario)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $case | Out-Null
        $source = Get-Content "$repo\Install-Apps.ps1" -Raw
        $tokens=$null; $errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $funcs=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)
        $admin=$funcs | Where-Object Name -eq 'Test-IsAdmin'
        $source=$source.Replace($admin.Extent.Text,'function Test-IsAdmin { return $true }')
        $pending=$funcs | Where-Object Name -eq 'Test-PendingReboot'
        $source=$source.Replace($pending.Extent.Text,'function Test-PendingReboot { return $false }')
        $timed=$funcs | Where-Object Name -eq 'Invoke-Timed'
        $fake=@'
function Invoke-Timed {
 param($FilePath,$ArgumentList,$TimeoutMin,[switch]$Quiet)
 Add-Content "$PSScriptRoot\calls.txt" ($FilePath + ' ' + ($ArgumentList -join ' '))
 if ($ArgumentList -contains 'list') { return 1 }
 if ('SCENARIO' -eq 'wsl-boot' -and ($ArgumentList -join ' ') -match 'Initialize-WSL.ps1') { return 3010 }
 if ($ArgumentList -contains 'Fixture.First') {
   if ('SCENARIO' -eq 'exception') { throw 'fixture launch exception' }
   if ('SCENARIO' -eq 'reboot') { return 3010 }
   return 1
 }
 return 0
}
'@
        $source=$source.Replace($timed.Extent.Text,$fake.Replace('SCENARIO',$Scenario))
        Set-Content "$case\Install-Apps.ps1" $source -Encoding UTF8
        Set-Content "$case\catalog.json" '{"first":{"content":"First","winget":"Fixture.First","choco":"fixture-first"},"second":{"content":"Second","winget":"Fixture.Second","choco":"fixture-second"}}'
        if ($Scenario -eq 'wsl-boot') {
            (Get-Content "$case\catalog.json" -Raw).Replace('Fixture.First','Docker.DockerDesktop') | Set-Content "$case\catalog.json"
        }
        $wrapper=@'
$env:LOCALAPPDATA=$PSScriptRoot
function winget {}
function choco {}
function Add-AppxPackage { throw 'Fixture: App Installer registration unavailable' }
& "$PSScriptRoot\Install-Apps.ps1" -NoRebootPrompt -Apps first,second -Catalog "$PSScriptRoot\catalog.json"
exit $LASTEXITCODE
'@
        if ($Scenario -eq 'missing-winget') {
            $wrapper=$wrapper.Replace('function winget {}', 'function Get-Command { param($Name) if ($Name -eq "winget") { return $null }; Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue }')
        }
        if ($Scenario -eq 'missing-both') {
            $wrapper=$wrapper.Replace('function winget {}', 'function Get-Command { param($Name) if ($Name -in @("winget","choco")) { return $null }; Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue }')
        }
        if ($Scenario -eq 'retry') {
            Set-Content "$case\previous.json" '[{"Slug":"first","Status":"Failed"},{"Slug":"second","Status":"Installed"}]'
            $wrapper=$wrapper.Replace('-Apps first,second', '-RetryReport "$PSScriptRoot\previous.json"')
        }
        Set-Content "$case\wrapper.ps1" $wrapper
        & $ps51 -NoProfile -ExecutionPolicy Bypass -File "$case\wrapper.ps1" *> "$case\out.txt"
        $code=$LASTEXITCODE
        $report=Get-ChildItem "$case\Upkeep\Reports\apps-*.json" | Select-Object -First 1
        [pscustomobject]@{Code=$code; Results=@((Get-Content $report.FullName -Raw | ConvertFrom-Json)); Calls=(Get-Content "$case\calls.txt" -Raw); Output=(Get-Content "$case\out.txt" -Raw)}
    }
}
Describe 'New PC app installer fault isolation (no real installers)' {
    It 'records an exception and continues to the next app' {
        $r=Invoke-InstallFixture exception
        $r.Code | Should -Be 1
        $r.Results[0].Status | Should -Be 'Failed'
        $r.Results[1].Status | Should -Be 'Installed'
    }
    It 'uses Chocolatey when winget is absent' {
        $r=Invoke-InstallFixture missing-winget
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'choco install fixture-first'
        $r.Calls | Should -Not -Match 'winget install'
    }
    It 'treats reboot-required success as installed without duplicate fallback' {
        $r=Invoke-InstallFixture reboot
        $r.Code | Should -Be 0
        $r.Results[0].ExitCode | Should -Be 3010
        $r.Calls | Should -Not -Match 'choco install fixture-first'
    }
    It 'recovers a winget failure using the catalog Chocolatey mapping' {
        $r=Invoke-InstallFixture fallback
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'choco install fixture-first'
        $r.Results.Count | Should -Be 2
    }
    It 'records every unavailable app when neither manager can be recovered' {
        $r=Invoke-InstallFixture missing-both
        $r.Code | Should -Be 1
        $r.Results.Count | Should -Be 2
        @($r.Results | Where-Object Status -eq 'Failed').Count | Should -Be 2
        $r.Calls | Should -Not -Match '(winget|choco) install'
    }
    It 'retries only failed apps from a previous report' {
        $r=Invoke-InstallFixture retry
        $r.Code | Should -Be 0
        $r.Results.Count | Should -Be 1
        $r.Results[0].Slug | Should -Be 'first'
        $r.Calls | Should -Not -Match 'Fixture.Second'
    }
    It 'defers Docker after enabling WSL features and still installs unrelated apps' {
        $r=Invoke-InstallFixture wsl-boot
        $r.Results[0].Status | Should -Be 'Deferred'
        $r.Results[0].RebootRequired | Should -BeTrue
        $r.Results[1].Status | Should -Be 'Installed'
        $r.Calls | Should -Not -Match 'install --id Docker.DockerDesktop'
    }
}

Describe 'Setup preview and invalid configuration' {
    It 'restores each saved registry value and removes values that did not exist' {
        $case = Join-Path $TestDrive 'restore-registry'
        New-Item -ItemType Directory -Path $case | Out-Null
        Copy-Item "$repo\steps\Restore-SetupRegistry.ps1" $case
        Set-Content "$case\backup.json" '[{"Path":"HKCU:\\Fixture","Name":"Existing","Exists":true,"Value":7,"Type":"DWord"},{"Path":"HKCU:\\Fixture","Name":"Added","Exists":false,"Value":null,"Type":"DWord"}]'
        $wrapper=@'
function Test-Path { return $true }
function Set-ItemProperty { param($LiteralPath,$Name,$Value,$Type) Add-Content "$PSScriptRoot\calls.txt" "set $Name $Value $Type" }
function Remove-ItemProperty { param($LiteralPath,$Name) Add-Content "$PSScriptRoot\calls.txt" "remove $Name" }
& "$PSScriptRoot\Restore-SetupRegistry.ps1" -Backup "$PSScriptRoot\backup.json"
exit $LASTEXITCODE
'@
        Set-Content "$case\run.ps1" $wrapper
        & $ps51 -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-Null
        $LASTEXITCODE | Should -Be 0
        $calls=@(Get-Content "$case\calls.txt")
        $calls.Count | Should -Be 2
        $calls[0] | Should -Be 'remove Added'
        $calls[1] | Should -Be 'set Existing 7 DWord'
    }
    It 'keeps an explicitly empty toggle selection empty' {
        $case = Join-Path $TestDrive 'empty-toggles'
        New-Item -ItemType Directory -Path $case | Out-Null
        $wrapper = '$env:LOCALAPPDATA = "' + $case + '"; & "' + $repo + '\Setup-NewPC.ps1" -DryRun -SkipRestorePoint -SkipTweaks -SkipDrivers -SkipApps -NoToggles; exit $LASTEXITCODE'
        Set-Content "$case\run.ps1" $wrapper
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'None selected'
        $output | Should -Not -Match "Would apply '"
    }
    It 'reports malformed tweak JSON and still reaches the final summary' {
        $case = Join-Path $TestDrive 'bad-config'
        New-Item -ItemType Directory -Path $case | Out-Null
        Set-Content "$case\invalid.json" '{broken'
        $wrapper = '$env:LOCALAPPDATA = "' + $case + '"; & "' + $repo + '\Setup-NewPC.ps1" -DryRun -SkipRestorePoint -SkipDrivers -SkipApps -NoToggles -WinutilConfig "' + $case + '\invalid.json"; exit $LASTEXITCODE'
        Set-Content "$case\run.ps1" $wrapper
        $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File "$case\run.ps1" | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'SETUP SUMMARY'
        $output | Should -Match 'Invalid config'
        @(Get-ChildItem "$case\Upkeep\Reports" -Filter results.json -Recurse).Count | Should -Be 1
    }
}
