BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-FakeClients {
        param([int]$Parallel = 3, [int]$Timeout = 15, [string]$Store = 'exit 0',
            [string]$JD = 'exit 0', [string]$Steam = 'exit 0')
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\Invoke-ClientUpdates.ps1" $case
        Set-Content "$case\Update-StoreApps.ps1" $Store
        Set-Content "$case\Update-JDownloader.ps1" $JD
        Set-Content "$case\Update-SteamGames.ps1" $Steam
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\Invoke-ClientUpdates.ps1" `
            -ResultFile "$case\result.txt" -LogFile "$case\run.log" -MaxParallel $Parallel -TimeoutSec $Timeout | Out-Null
        [pscustomobject]@{ Code=$LASTEXITCODE; Path=$case; Result=(Get-Content "$case\result.txt" -Raw) }
    }
}
Describe 'Independent client workers (fake updaters, no installed applications touched)' {
    BeforeEach {
        $savedSkip = @{}
        foreach ($key in @('DASHBOARD_SKIP_APPS','DASHBOARD_SKIP_STORE','DASHBOARD_SKIP_STEAM','DASHBOARD_SKIP_OTHER_APPS')) {
            $savedSkip[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, $null)
        }
    }
    AfterEach {
        foreach ($key in $savedSkip.Keys) { [Environment]::SetEnvironmentVariable($key, $savedSkip[$key]) }
    }
    It 'preserves successful, skipped and failed exit codes and logs stderr' {
        $run = Invoke-FakeClients -JD 'exit 2' -Steam '[Console]::Error.WriteLine("fixture failure"); exit 1'
        $run.Code | Should -Be 1
        $run.Result | Should -Match 'STORE_STATUS=ok'
        $run.Result | Should -Match 'JD_STATUS=skipped'
        $run.Result | Should -Match 'STEAM_STATUS=error'
        Get-Content "$($run.Path)\run.log" -Raw | Should -Match 'fixture failure'
    }
    It 'actually overlaps independent workers' {
        $body = @'
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
[datetime]::UtcNow.Ticks | Set-Content (Join-Path $PSScriptRoot ($name + '.start'))
Start-Sleep -Seconds 2
[datetime]::UtcNow.Ticks | Set-Content (Join-Path $PSScriptRoot ($name + '.end'))
exit 0
'@
        $run = Invoke-FakeClients -Store $body -JD $body -Steam $body
        $run.Code | Should -Be 0
        $starts = Get-ChildItem $run.Path -Filter '*.start' | ForEach-Object { [long](Get-Content $_.FullName) }
        $ends = Get-ChildItem $run.Path -Filter '*.end' | ForEach-Object { [long](Get-Content $_.FullName) }
        $starts.Count | Should -Be 3
        ($starts | Measure-Object -Maximum).Maximum | Should -BeLessThan ($ends | Measure-Object -Minimum).Minimum
    }
    It 'supports serial execution without overlap' {
        $body = @'
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
[datetime]::UtcNow.Ticks | Set-Content (Join-Path $PSScriptRoot ($name + '.start'))
Start-Sleep -Milliseconds 300
[datetime]::UtcNow.Ticks | Set-Content (Join-Path $PSScriptRoot ($name + '.end'))
'@
        $run = Invoke-FakeClients -Parallel 1 -Store $body -JD $body -Steam $body
        $run.Code | Should -Be 0
        [long](Get-Content "$($run.Path)\Update-JDownloader.start") | Should -BeGreaterThan ([long](Get-Content "$($run.Path)\Update-StoreApps.end"))
    }
    It 'honors skipped categories without launching workers' {
        $env:DASHBOARD_SKIP_APPS = '1'; $env:DASHBOARD_SKIP_STORE = '1'; $env:DASHBOARD_SKIP_STEAM = '1'
        $run = Invoke-FakeClients -Store 'throw "must not run"' -JD 'throw "must not run"' -Steam 'throw "must not run"'
        $run.Code | Should -Be 0
        ($run.Result -split 'skipped').Count | Should -Be 4
    }
    It 'keeps JDownloader out of a reviewed WinGet and Store run' {
        $env:DASHBOARD_SKIP_OTHER_APPS = '1'
        $run = Invoke-FakeClients -JD 'throw "unchecked provider must not run"'
        $run.Code | Should -Be 0
        $run.Result | Should -Match 'JD_STATUS=skipped'
        $run.Result | Should -Match 'STORE_STATUS=ok'
        $run.Result | Should -Match 'STEAM_STATUS=ok'
    }
    It 'bounds a hung worker and continues to the next queued client' {
        $run = Invoke-FakeClients -Parallel 1 -Timeout 2 -Store 'Start-Sleep -Seconds 60'
        $run.Code | Should -Be 1
        $run.Result | Should -Match 'STORE_STATUS=error'
        $run.Result | Should -Match 'JD_STATUS=ok'
        $run.Result | Should -Match 'STEAM_STATUS=ok'
        Get-Content "$($run.Path)\run.log" -Raw | Should -Match '\[timeout\]'
    }
}
