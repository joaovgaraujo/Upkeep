BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # Starts a step script in Windows PowerShell 5.1 (what the bat uses) and
    # returns the process, so a test can inspect the log WHILE it runs.
    function Start-Step {
        param([string]$Script, [string[]]$Arguments)
        $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + $Arguments
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.out'))
        # Windows PowerShell 5.1 (what CI runs Pester under) only reports
        # .ExitCode if the handle was acquired while the process was alive.
        $null = $proc.Handle
        $proc
    }

    function Wait-ForText {
        param([string]$Path, [string]$Pattern, [int]$TimeoutSec = 20)
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path $Path) -and ((Get-Content $Path -Raw) -match $Pattern)) { return $true }
            Start-Sleep -Milliseconds 100
        }
        $false
    }
}

Describe 'topgrade output streams as it is produced' {
    BeforeAll {
        # A fake topgrade: one line, a silent stretch, another line, exit 7.
        $fake = Join-Path $TestDrive 'fake-topgrade.cmd'
        Set-Content $fake -Encoding Ascii -Value @(
            '@echo first line'
            '@powershell -NoProfile -Command "Start-Sleep -Seconds 4"'
            '@echo second line'
            '@exit /b 7'
        )
    }
    It 'logs early output before the program finishes and keeps its exit code' {
        $log = Join-Path $TestDrive 'topgrade.log'
        $proc = Start-Step "$repoRoot\steps\Invoke-Topgrade.ps1" @('-ConfigPath', 'unused.toml', '-LogFile', "`"$log`"", '-Executable', "`"$fake`"", '-HeartbeatSec', '2')
        Wait-ForText $log 'first line' | Should -BeTrue
        (Get-Content $log -Raw) | Should -Not -Match 'second line'
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 7
        $text = Get-Content $log -Raw
        $text | Should -Match '\[topgrade\] still running'
        $text | Should -Match 'second line'
        $text | Should -Match '\[topgrade\] finished in .* \(exit 7\)'
    }
    It 'kills a hung program at the timeout and reports it' {
        . "$repoRoot\steps\Stream-Process.ps1"
        $hung = Join-Path $TestDrive 'hung.cmd'
        Set-Content $hung -Encoding Ascii -Value '@powershell -NoProfile -Command "Start-Sleep -Seconds 60"'
        $log = Join-Path $TestDrive 'timeout.log'
        $code = Invoke-StreamedProcess -FilePath $hung -Tag 'fixture' -LogFile $log -TimeoutSec 2 -HeartbeatSec 60 6>$null
        $code | Should -Be 1
        Get-Content $log -Raw | Should -Match '\[timeout\] fixture exceeded'
    }
    It 'reports a program that cannot be started instead of throwing' {
        . "$repoRoot\steps\Stream-Process.ps1"
        $log = Join-Path $TestDrive 'missing.log'
        Invoke-StreamedProcess -FilePath (Join-Path $TestDrive 'no-such-program.exe') -Tag 'fixture' -LogFile $log 6>$null | Should -Be 1
        Get-Content $log -Raw | Should -Match '\[error\] Could not start'
    }
}

Describe 'Windows Update progress streams from the job' {
    It 'shows job output while the job is still running' {
        $log = Join-Path $TestDrive 'wu.log'
        $runner = Join-Path $TestDrive 'wu-runner.ps1'
        Set-Content $runner -Value @"
& '$repoRoot\steps\Invoke-WindowsUpdate.ps1' -LogFile '$log' -HeartbeatSec 2 -JobBody { 'Downloading KB0000001'; Start-Sleep -Seconds 5; 'Installed KB0000001' }
exit `$LASTEXITCODE
"@
        $proc = Start-Step $runner @()
        Wait-ForText $log 'Downloading KB0000001' | Should -BeTrue
        (Get-Content $log -Raw) | Should -Not -Match 'Installed KB0000001'
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
        $text = Get-Content $log -Raw
        $text | Should -Match '\[winupdate\] still running'
        $text | Should -Match 'Installed KB0000001'
        $text | Should -Match '\[winupdate\] finished in .* \(ok\)'
    }
    It 'reports a failed job with its error and exit 1' {
        $log = Join-Path $TestDrive 'wu-fail.log'
        $runner = Join-Path $TestDrive 'wu-fail.ps1'
        Set-Content $runner -Value @"
& '$repoRoot\steps\Invoke-WindowsUpdate.ps1' -LogFile '$log' -JobBody { throw 'fixture module missing' }
exit `$LASTEXITCODE
"@
        $proc = Start-Step $runner @()
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 1
        $text = Get-Content $log -Raw
        $text | Should -Match '\[error\] fixture module missing'
        $text | Should -Match '\(error\)'
    }
    It 'retries a failed pass once and reports ok when the retry succeeds' {
        $log = Join-Path $TestDrive 'wu-retry.log'
        $marker = Join-Path $TestDrive 'wu-first-pass-ran'
        $runner = Join-Path $TestDrive 'wu-retry.ps1'
        # The marker file is how the second pass knows it is the second one:
        # each pass is a fresh job process.
        Set-Content $runner -Value @"
& '$repoRoot\steps\Invoke-WindowsUpdate.ps1' -LogFile '$log' -JobBody {
    if (-not (Test-Path '$marker')) { New-Item '$marker' | Out-Null; throw 'Exception from HRESULT: 0x80248007' }
    'Installed KB0000002'
}
exit `$LASTEXITCODE
"@
        $proc = Start-Step $runner @()
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
        $text = Get-Content $log -Raw
        $text | Should -Match '\[warn\] Exception from HRESULT: 0x80248007'
        $text | Should -Match 'retry 1 of 1'
        $text | Should -Match 'Installed KB0000002'
        $text | Should -Not -Match '\[error\]'
        $text | Should -Match '\[winupdate\] finished in .* \(ok\)'
    }
}

Describe 'Client worker output streams while the worker runs' {
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
    It 'forwards a long worker''s early lines before it exits, once each' {
        $case = Join-Path $TestDrive 'clients'
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item "$repoRoot\steps\Invoke-ClientUpdates.ps1", "$repoRoot\steps\Stream-Process.ps1" $case
        Set-Content "$case\Update-StoreApps.ps1" "Write-Output '[store] early progress'; Start-Sleep -Seconds 5; Write-Output '[store] late progress'; exit 0"
        Set-Content "$case\Update-JDownloader.ps1" 'exit 2'
        Set-Content "$case\Update-SteamGames.ps1" 'exit 2'
        $log = Join-Path $case 'run.log'
        $proc = Start-Step "$case\Invoke-ClientUpdates.ps1" @('-ResultFile', "`"$case\result.txt`"", '-LogFile', "`"$log`"", '-HeartbeatSec', '2')
        Wait-ForText $log '\[store\] early progress' | Should -BeTrue
        (Get-Content $log -Raw) | Should -Not -Match 'late progress'
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
        $text = Get-Content $log -Raw
        ([regex]::Matches($text, 'early progress')).Count | Should -Be 1
        ([regex]::Matches($text, 'late progress')).Count | Should -Be 1
        $text | Should -Match '\[store\] still running'
        $text | Should -Match '\[clients\] STORE: ok \(after'
    }
}
