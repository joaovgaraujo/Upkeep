BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-FakeWinget {
        param([ValidateSet('inventory-error','bulk-error','pending','recovered','current','localized','retry','selected','ignored','empty-selection','inventory','nonadmin','nonadmin-timeout','tight','unknown-installed','portable-lost','tech-mismatch','edge','winget-itself')][string]$Scenario)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\Update-WingetApps.ps1", "$repoRoot\steps\Deelevate.ps1" $case
        if ($Scenario -like 'nonadmin*') {
            Add-Content "$case\Deelevate.ps1" @'
function Test-Elevated { $true }
function Invoke-Deelevated {
    param($Command)
    Add-Content "$PSScriptRoot\calls.txt" 'NORMAL_USER_RETRY'
    if ($env:UPKEEP_FIXTURE_TIMEOUT -eq '1') { return [pscustomobject]@{ Status='TimedOut'; ExitCode=1; Output='may still be running' } }
    $global:normalUpdated = $true
    [pscustomobject]@{ Status='Completed'; ExitCode=0; Output='updated as normal user' }
}
'@
        }
        $wrapper = @'
$env:LOCALAPPDATA = $PSScriptRoot
$global:scan = 0
$global:normalUpdated = $false
$env:UPKEEP_FIXTURE_TIMEOUT = if ('SCENARIO' -eq 'nonadmin-timeout') { '1' } else { '0' }
Remove-Item Env:UPKEEP_SELECTED_IDS -ErrorAction SilentlyContinue
function winget {
    Add-Content "$PSScriptRoot\calls.txt" ($args -join ' ')
    $global:LASTEXITCODE = 0
    if ($args -contains '--all') {
        if ('SCENARIO' -eq 'bulk-error') { $global:LASTEXITCODE = 1 }
        return
    }
    if ('SCENARIO' -eq 'portable-lost') {
        # winget lists the portable package as upgradable but `upgrade --id` cannot match it.
        if ($args[0] -eq 'install' -and $args -contains '--force') { $global:normalUpdated = $true; 'Successfully installed'; return }
        if ($args -contains '--id') { $global:LASTEXITCODE = -1978335212; 'No installed package found matching input criteria.'; return }
    }
    if ($args -contains '--id' -and 'SCENARIO' -eq 'tech-mismatch') { $global:LASTEXITCODE = -1978335090; 'The install technology of the newer version specified is different from the current version installed.'; return }
    # App Installer upgrades fine, but winget keeps listing the old version.
    if ($args -contains '--id' -and 'SCENARIO' -eq 'winget-itself') { 'Successfully installed'; return }
    if ($args -contains '--id' -and 'SCENARIO' -like 'nonadmin*') { $global:LASTEXITCODE = -1978335146; 'localized refusal'; return }
    if ($args -contains '--id') { $global:LASTEXITCODE = 1; 'fixture installer failed'; return }
    $global:scan++
    if ($global:normalUpdated) { return }
    if ('SCENARIO' -eq 'inventory-error') { $global:LASTEXITCODE = 1; 'fixture source error'; return }
    if ('SCENARIO' -in @('bulk-error','current')) { return }
    if ('SCENARIO' -eq 'recovered' -and $global:scan -ge 3) { return }
    if ('SCENARIO' -eq 'tight') {
        # Real winget output: 'Version' and 'Unknown' are equally wide, so only one space separates the labels.
        'Name              Id                Version Available Source'
        '-' * 60
        'DiskGenius V6.0.0 Eassos.DiskGenius Unknown 6.0.0     winget'
        ''
        return
    }
    if ('SCENARIO' -eq 'unknown-installed') {
        # DisplayVersion is empty, so winget reports Unknown and offers an OLDER build than the name shows.
        '{0,-20}{1,-35}{2,-15}{3,-15}Source' -f 'Name','Id','Version','Available'
        '-' * 100
        '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'DiskGenius V6.2.0','Eassos.DiskGenius','Unknown','6.0.0'
        '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Fixture','Fixture.App','1','2'
        ''
        return
    }
    if ('SCENARIO' -eq 'localized') {
        '{0,-20}{1,-35}{2,-15}{3,-15}Fonte' -f 'Nome','Id','Versao','Disponivel'
    } else { '{0,-20}{1,-35}{2,-15}{3,-15}Source' -f 'Name','Id','Version','Available' }
    '-' * 100
    if ('SCENARIO' -eq 'winget-itself') { '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'App Installer','Microsoft.AppInstaller','1.26.509.0','1.29.380'; ''; return }
    if ('SCENARIO' -eq 'edge') { '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Microsoft Edge','Microsoft.Edge','154.0.1','154.0.2'; ''; return }
    '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Fixture','Fixture.App','1','2'
    if ('SCENARIO' -in @('retry','selected','ignored','empty-selection','inventory')) { '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Other','Fixture.Other','1','2' }
    ''
}
try {
if ('SCENARIO' -eq 'inventory') { & "$PSScriptRoot\Update-WingetApps.ps1" -InventoryOnly; exit $LASTEXITCODE }
if ('SCENARIO' -eq 'portable-lost') { New-Item "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Fixture.App_Microsoft.Winget.Source_8wekyb3d8bbwe" -ItemType Directory -Force | Out-Null }
if ('SCENARIO' -eq 'selected') { $env:UPKEEP_SELECTED_IDS = '["Fixture.App"]' }
if ('SCENARIO' -eq 'empty-selection') { $env:UPKEEP_SELECTED_IDS = '[]' }
if ('SCENARIO' -eq 'ignored') {
    New-Item "$env:LOCALAPPDATA\Upkeep" -ItemType Directory -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\Upkeep\winget-ignore.json" '["Fixture.Other"]'
}
if ('SCENARIO' -eq 'retry') {
    New-Item "$env:LOCALAPPDATA\Upkeep\Reports" -ItemType Directory -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\Upkeep\Reports\winget-failed.json" '["Fixture.App"]'
    & "$PSScriptRoot\Update-WingetApps.ps1" -NoChocoFallback -NoDeelevatedRetry -RetryFailed
} elseif ('SCENARIO' -like 'nonadmin*') { & "$PSScriptRoot\Update-WingetApps.ps1" -NoChocoFallback }
else { & "$PSScriptRoot\Update-WingetApps.ps1" -NoChocoFallback -NoDeelevatedRetry }
exit $LASTEXITCODE
} catch { Write-Output $_.Exception.Message; exit 1 }
'@
        Set-Content "$case\wrapper.ps1" $wrapper.Replace('SCENARIO', $Scenario)
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\wrapper.ps1" *> "$case\output.txt"
        $code = $LASTEXITCODE
        $manualFile = "$case\Upkeep\Reports\manual-updates-winget.json"
        $failedFile = "$case\Upkeep\Reports\winget-failed.json"
        [pscustomobject]@{ Code=$code; Output=(Get-Content "$case\output.txt" -Raw); Calls=(Get-Content "$case\calls.txt" -Raw)
            Manual=$(if (Test-Path $manualFile) { @(Get-Content $manualFile -Raw | ConvertFrom-Json) } else { @() })
            Failed=$(if (Test-Path $failedFile) { @(Get-Content $failedFile -Raw | ConvertFrom-Json) } else { @() }) }
    }
}
Describe 'Winget results with fake inventory and installers' {
    It 'reports a failed inventory instead of claiming nothing is pending' {
        (Invoke-FakeWinget inventory-error).Code | Should -Be 1
    }
    It 'preserves a failed bulk command even when snapshots are empty' {
        (Invoke-FakeWinget bulk-error).Code | Should -Be 1
    }
    It 'reports unresolved upgrades after the individual retry' {
        $run = Invoke-FakeWinget pending
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'could not update 1 package'
    }
    It 'returns success when a final inventory confirms recovery' {
        (Invoke-FakeWinget recovered).Code | Should -Be 0
    }
    It 'returns success when nothing needs updating' {
        (Invoke-FakeWinget current).Code | Should -Be 0
    }
    It 'parses translated inventory headings' {
        $r=Invoke-FakeWinget localized
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Fixture.App'
    }
    It 'parses headings winget separates with a single space' {
        $r = Invoke-FakeWinget tight
        $r.Output | Should -Not -Match 'Unrecognized winget inventory columns'
        $r.Output | Should -Match 'Eassos.DiskGenius'
    }
    It 'does not reinstall or downgrade an Unknown-version app whose name shows a newer version' {
        $r = Invoke-FakeWinget unknown-installed
        $r.Output | Should -Match 'Eassos.DiskGenius : skipped'
        $r.Calls | Should -Match '--id Fixture.App'
        $r.Calls | Should -Not -Match '--all|--id Eassos.DiskGenius'
    }
    It 'retries the recorded app without a bulk update or unrelated installs' {
        $r=Invoke-FakeWinget retry
        $r.Code | Should -Be 1
        $r.Calls | Should -Match '--id Fixture.App'
        $r.Calls | Should -Not -Match '--all|--id Fixture.Other'
    }
    It 'takes App Installer''s success at its word instead of reinstalling it' {
        $r = Invoke-FakeWinget winget-itself
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'App Installer is winget itself'
        ([regex]::Matches($r.Calls, '--id Microsoft.AppInstaller')).Count | Should -Be 1
        $r.Failed.Count | Should -Be 0
    }
}

Describe 'Etcher per-user installer' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$repoRoot/steps/Update-WingetApps.ps1", [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WingetUpgrade' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        function Test-Elevated { $true }
        function Get-InstallScope { param($Id) 'user' }
        function Invoke-Deelevated { param($Command) }
    }
    BeforeEach {
        $script:etcherWorkerAttempt = $null
        $NoDeelevatedRetry = $false
    }
    It 'runs the per-user installer once even if its worker times out' {
        Mock Invoke-Deelevated { [pscustomobject]@{ ExitCode = 1; Status = 'TimedOut'; Output = 'Installer may still be running' } }
        $first = Invoke-WingetUpgrade -Id 'Balena.Etcher'
        $second = Invoke-WingetUpgrade -Id 'Balena.Etcher'
        $first.ExitCode | Should -Be 1
        $second.Output | Should -Match 'still be running'
        Should -Invoke Invoke-Deelevated -Times 1 -Exactly -ParameterFilter { $Command -match '--id Balena.Etcher --exact' }
    }
    It 'honors disabled normal-user execution without falling back to elevation' {
        $NoDeelevatedRetry = $true
        Mock Invoke-Deelevated { throw 'must not start' }
        (Invoke-WingetUpgrade -Id 'Balena.Etcher').ExitCode | Should -Be 1
        Should -Invoke Invoke-Deelevated -Times 0 -Exactly
    }
}

Describe 'Portable package winget cannot match for upgrade' {
    It 'reinstalls it with --force and confirms with another inventory' {
        $r = Invoke-FakeWinget portable-lost
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'install --id Fixture.App --exact --force'
        $r.Output | Should -Match 'reinstalled at the new version'
    }
    It 'does not force-install a non-portable app that winget cannot match' {
        $r = Invoke-FakeWinget pending
        $r.Calls | Should -Not -Match 'install --id'
    }
}

Describe 'Reviewed update boundaries' {
    It 'only upgrades explicitly selected IDs' {
        $r = Invoke-FakeWinget selected
        $r.Output | Should -Match '\(1/1\) Fixture.App 1 -> 2'
        $r.Calls | Should -Match '--id Fixture.App'
        $r.Calls | Should -Not -Match '--all|--id Fixture.Other'
    }
    It 'keeps ignored apps out of automatic and retry passes' {
        $r = Invoke-FakeWinget ignored
        $r.Calls | Should -Match '--id Fixture.App'
        $r.Calls | Should -Not -Match '--all|--id Fixture.Other'
        $r.Output | Should -Not -Match 'still has 2 pending'
    }
    It 'does not interpret an empty selection as update all' {
        $r = Invoke-FakeWinget empty-selection
        $r.Code | Should -Be 0
        $r.Calls | Should -Not -Match '--all|--id'
    }
    It 'checks without invoking an installer and emits a JSON array' {
        $r = Invoke-FakeWinget inventory
        $r.Code | Should -Be 0
        $r.Calls | Should -Not -Match '--all|--id'
        $items = @(($r.Output | ConvertFrom-Json))
        $items.Count | Should -Be 2
        $items[0].Current | Should -Be '1'
        $items[0].Available | Should -Be '2'
    }
}

Describe 'Installer prohibits elevation recovery' {
    It 'retries as normal user and confirms success with another inventory' {
        $r = Invoke-FakeWinget nonadmin
        $r.Code | Should -Be 0
        $r.Calls | Should -Match 'NORMAL_USER_RETRY'
        $r.Output | Should -Match 'upgraded unelevated'
    }
    It 'reports a still-running installer without a forced retry' {
        $r = Invoke-FakeWinget nonadmin-timeout
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'TimedOut.*may still be running'
        $r.Calls | Should -Not -Match '--force'
        ([regex]::Matches($r.Calls,'NORMAL_USER_RETRY')).Count | Should -Be 1
    }
}

Describe 'Apps winget cannot update here are reported, not failed' {
    It 'lists an installer-type change for a manual update and exits 3' {
        $r = Invoke-FakeWinget tech-mismatch
        $r.Code | Should -Be 3
        $r.Output | Should -Not -Match '\[error\]'
        $r.Manual.Count | Should -Be 1
        $r.Manual[0].Id | Should -Be 'Fixture.App'
        $r.Manual[0].Fix | Should -Match 'winget uninstall --id Fixture.App'
        @($r.Failed | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'never runs winget for Edge and never suggests uninstalling it' {
        $r = Invoke-FakeWinget edge
        $r.Code | Should -Be 3
        $r.Calls | Should -Not -Match 'upgrade --id Microsoft.Edge|--all'
        $r.Manual[0].Fix | Should -Match 'edge://settings/help'
        $r.Output | Should -Not -Match 'winget uninstall --id Microsoft.Edge'
    }
    It 'keeps genuine installer failures as errors' {
        $r = Invoke-FakeWinget pending
        $r.Code | Should -Be 1
        $r.Manual.Count | Should -Be 0
        @($r.Failed) | Should -Contain 'Fixture.App'
    }
}

Describe 'Closing an app before its installer runs' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$repoRoot/steps/Update-WingetApps.ps1", [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-AppForUpgrade' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $script:closeBeforeUpgrade = @{ 'EpicGames.EpicGamesLauncher' = @{ Processes = @('EpicGamesLauncher', 'EpicWebHelper'); Main = 'EpicGamesLauncher'; Arguments = '-silent' } }
    }
    It 'closes a running Epic launcher and returns how to start it again' {
        Mock Get-Process { @([pscustomobject]@{ ProcessName = 'EpicGamesLauncher'; Path = 'C:\Epic\EpicGamesLauncher.exe' }) }
        Mock Stop-Process { }
        Mock Start-Sleep { }
        $r = Stop-AppForUpgrade -Id 'EpicGames.EpicGamesLauncher'
        $r.Path | Should -Be 'C:\Epic\EpicGamesLauncher.exe'
        $r.Arguments | Should -Be '-silent'
        Should -Invoke Stop-Process -Times 1 -Exactly
    }
    It 'does nothing for other apps or when the app is not running' {
        Mock Get-Process { @() }
        Mock Stop-Process { }
        Stop-AppForUpgrade -Id 'EpicGames.EpicGamesLauncher' | Should -BeNullOrEmpty
        Stop-AppForUpgrade -Id 'Fixture.App' | Should -BeNullOrEmpty
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}
