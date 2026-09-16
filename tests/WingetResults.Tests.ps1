BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-FakeWinget {
        param([ValidateSet('inventory-error','bulk-error','pending','recovered','current','localized','retry')][string]$Scenario)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\Update-WingetApps.ps1", "$repoRoot\steps\Deelevate.ps1" $case
        $wrapper = @'
$env:LOCALAPPDATA = $PSScriptRoot
$global:scan = 0
function winget {
    Add-Content "$PSScriptRoot\calls.txt" ($args -join ' ')
    $global:LASTEXITCODE = 0
    if ($args -contains '--all') {
        if ('SCENARIO' -eq 'bulk-error') { $global:LASTEXITCODE = 1 }
        return
    }
    if ($args -contains '--id') { $global:LASTEXITCODE = 1; 'fixture installer failed'; return }
    $global:scan++
    if ('SCENARIO' -eq 'inventory-error') { $global:LASTEXITCODE = 1; 'fixture source error'; return }
    if ('SCENARIO' -in @('bulk-error','current')) { return }
    if ('SCENARIO' -eq 'recovered' -and $global:scan -ge 3) { return }
    if ('SCENARIO' -eq 'localized') {
        '{0,-20}{1,-35}{2,-15}{3,-15}Fonte' -f 'Nome','Id','Versao','Disponivel'
    } else { '{0,-20}{1,-35}{2,-15}{3,-15}Source' -f 'Name','Id','Version','Available' }
    '-' * 100
    '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Fixture','Fixture.App','1','2'
    if ('SCENARIO' -eq 'retry') { '{0,-20}{1,-35}{2,-15}{3,-15}winget' -f 'Other','Fixture.Other','1','2' }
    ''
}
if ('SCENARIO' -eq 'retry') {
    New-Item "$env:LOCALAPPDATA\Upkeep\Reports" -ItemType Directory -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\Upkeep\Reports\winget-failed.json" '["Fixture.App"]'
    & "$PSScriptRoot\Update-WingetApps.ps1" -NoChocoFallback -NoDeelevatedRetry -RetryFailed
} else { & "$PSScriptRoot\Update-WingetApps.ps1" -NoChocoFallback -NoDeelevatedRetry }
exit $LASTEXITCODE
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
    It 'retries the recorded app without a bulk update or unrelated installs' {
        $r=Invoke-FakeWinget retry
        $r.Code | Should -Be 1
        $r.Calls | Should -Match '--id Fixture.App'
        $r.Calls | Should -Not -Match '--all|--id Fixture.Other'
    }
}
