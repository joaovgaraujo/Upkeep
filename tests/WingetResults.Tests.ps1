BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-FakeWinget {
        param([ValidateSet('inventory-error','bulk-error','pending','recovered','current','localized','retry','selected','ignored','empty-selection','inventory','nonadmin','nonadmin-timeout','tight','unknown-installed')][string]$Scenario)
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
    '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Fixture','Fixture.App','1','2'
    if ('SCENARIO' -in @('retry','selected','ignored','empty-selection','inventory')) { '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Other','Fixture.Other','1','2' }
    ''
}
try {
if ('SCENARIO' -eq 'inventory') { & "$PSScriptRoot\Update-WingetApps.ps1" -InventoryOnly; exit $LASTEXITCODE }
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
        [pscustomobject]@{ Code=$LASTEXITCODE; Output=(Get-Content "$case\output.txt" -Raw); Calls=(Get-Content "$case\calls.txt" -Raw) }
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
        $run.Output | Should -Match 'still has 1 pending package'
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
}

Describe 'Reviewed update boundaries' {
    It 'only upgrades explicitly selected IDs' {
        $r = Invoke-FakeWinget selected
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
