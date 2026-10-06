BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $featureStep = Join-Path $repoRoot 'steps\Invoke-FeatureUpdate.ps1'
    $waitStep = Join-Path $repoRoot 'steps\Wait-BackgroundStep.ps1'
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # Same shape as tests\StreamingProgress.Tests.ps1: run the step in Windows
    # PowerShell 5.1 (what the bat uses) and look at the log while it runs.
    function Start-Step {
        param([string]$Script, [string[]]$Arguments)
        $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + $Arguments
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.out'))
        # Windows PowerShell 5.1 only reports .ExitCode if the handle was
        # acquired while the process was alive.
        $null = $proc.Handle
        $proc
    }

    function Wait-ForText {
        param([string]$Path, [string]$Pattern, [int]$TimeoutSec = 30)
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path $Path) -and ((Get-Content $Path -Raw) -match $Pattern)) { return $true }
            Start-Sleep -Milliseconds 100
        }
        $false
    }

    function Invoke-FeatureStep {
        param([string[]]$Arguments, [int]$TimeoutSec = 60)
        $proc = Start-Step $featureStep $Arguments
        $proc.WaitForExit($TimeoutSec * 1000) | Out-Null
        $proc
    }
}

Describe 'the feature update step reports "not applicable" instead of failing' {
    It 'exits 2 when Windows is already at or past the target build' {
        $log = Join-Path $TestDrive 'already.log'
        # Target build 1: every real machine is already past it.
        $proc = Invoke-FeatureStep @('-LogFile', "`"$log`"", '-TargetBuild', '1')
        $proc.ExitCode | Should -Be 2
        (Get-Content $log -Raw) | Should -Match 'nothing to upgrade'
    }

    It 'exits 2 when this build is not on the enablement package branch' {
        $log = Join-Path $TestDrive 'branch.log'
        $proc = Invoke-FeatureStep @(
            '-LogFile', "`"$log`"", '-TargetBuild', '99999', '-SupportedBuilds', '1'
        )
        $proc.ExitCode | Should -Be 2
        (Get-Content $log -Raw) | Should -Match 'installation media'
    }
}

Describe 'the feature update step changes nothing on a dry run' {
    It 'reports the deferral and the prerequisite without touching either' {
        $log = Join-Path $TestDrive 'dry.log'
        $proc = Invoke-FeatureStep @(
            '-LogFile', "`"$log`"", '-TargetBuild', '99999', '-SupportedBuilds',
            "$([int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)",
            '-PrerequisiteUbr', '99999', '-DryRun'
        )
        $proc.ExitCode | Should -Be 0
        $text = Get-Content $log -Raw
        $text | Should -Match '\[dry-run\] would install cumulative updates'
        # No policy backup is written when nothing is changed.
        Get-ChildItem $TestDrive -Filter 'FeatureUpdate_PolicyBackup_*.json' | Should -BeNullOrEmpty
    }
}

Describe 'prerequisite progress streams while the job runs' {
    BeforeAll {
        $script:currentBuild = "$([int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)"
    }

    It 'shows job output before the job has finished' {
        $log = Join-Path $TestDrive 'stream.log'
        $runner = Join-Path $TestDrive 'feature-runner.ps1'
        # A literal scriptblock has to go through a runner file: -JobBody style
        # arguments cannot survive the command line.
        Set-Content $runner -Value @"
& '$featureStep' -LogFile '$log' -TargetBuild 99999 -SupportedBuilds $script:currentBuild ``
    -PrerequisiteUbr 99999 -KeepDeferralPolicy -HeartbeatSec 2 ``
    -PrerequisiteJobBody { 'Downloading KB0000001'; Start-Sleep -Seconds 6; 'Installed KB0000001' }
exit `$LASTEXITCODE
"@
        $proc = Start-Step $runner @()
        Wait-ForText $log 'Downloading KB0000001' | Should -BeTrue
        (Get-Content $log -Raw) | Should -Not -Match 'Installed KB0000001'
        $proc.WaitForExit(60000) | Should -BeTrue
    }

    It 'fails with exit 1 when the prerequisite job faults' {
        $log = Join-Path $TestDrive 'fail.log'
        $runner = Join-Path $TestDrive 'feature-fail-runner.ps1'
        Set-Content $runner -Value @"
& '$featureStep' -LogFile '$log' -TargetBuild 99999 -SupportedBuilds $script:currentBuild ``
    -PrerequisiteUbr 99999 -KeepDeferralPolicy ``
    -PrerequisiteJobBody { throw 'fixture module missing' }
exit `$LASTEXITCODE
"@
        $proc = Start-Step $runner @()
        $proc.WaitForExit(60000) | Should -BeTrue
        $proc.ExitCode | Should -Be 1
        $text = Get-Content $log -Raw
        $text | Should -Match '\[error\] fixture module missing'
        $text | Should -Match 'did not complete'
    }
}

Describe 'the background client lane is joined before the summary' {
    It 'returns immediately when no lane was started' {
        $log = Join-Path $TestDrive 'nopid.log'
        $proc = Start-Step $waitStep @('-PidFile', "`"$(Join-Path $TestDrive 'missing.pid')`"", '-LogFile', "`"$log`"")
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
    }

    It 'waits for a running worker and reports how long it took' {
        $log = Join-Path $TestDrive 'wait.log'
        $pidFile = Join-Path $TestDrive 'lane.pid'
        $worker = Start-Process -FilePath $windowsPowerShell `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 4') -PassThru -WindowStyle Hidden
        $null = $worker.Handle
        "$($worker.Id) $($worker.StartTime.ToString('o'))" | Set-Content -LiteralPath $pidFile -Encoding ASCII

        $proc = Start-Step $waitStep @('-PidFile', "`"$pidFile`"", '-LogFile', "`"$log`"", '-Tag', 'clients')
        $proc.WaitForExit(60000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
        $worker.HasExited | Should -BeTrue
        (Get-Content $log -Raw) | Should -Match '\[clients\] Client updates finished'
    }

    It 'does not wait on a PID the OS has recycled for something else' {
        $log = Join-Path $TestDrive 'recycled.log'
        $pidFile = Join-Path $TestDrive 'recycled.pid'
        # This process is alive, but the recorded start time belongs to another.
        "$PID 2000-01-01T00:00:00.0000000Z" | Set-Content -LiteralPath $pidFile -Encoding ASCII
        $proc = Start-Step $waitStep @('-PidFile', "`"$pidFile`"", '-LogFile', "`"$log`"", '-Tag', 'clients')
        $proc.WaitForExit(30000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
        (Get-Content $log -Raw) | Should -Match 'different process now'
    }

    It 'gives up with exit 1 when the worker outlives the timeout' {
        $log = Join-Path $TestDrive 'timeout.log'
        $pidFile = Join-Path $TestDrive 'timeout.pid'
        $worker = Start-Process -FilePath $windowsPowerShell `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
        $null = $worker.Handle
        try {
            "$($worker.Id) $($worker.StartTime.ToString('o'))" | Set-Content -LiteralPath $pidFile -Encoding ASCII
            $proc = Start-Step $waitStep @(
                '-PidFile', "`"$pidFile`"", '-LogFile', "`"$log`"", '-Tag', 'clients', '-TimeoutSec', '3'
            )
            $proc.WaitForExit(60000) | Should -BeTrue
            $proc.ExitCode | Should -Be 1
            (Get-Content $log -Raw) | Should -Match '\[timeout\] The client lane exceeded 3 seconds'
            # The join must not kill the worker: its own step owns that.
            $worker.HasExited | Should -BeFalse
        } finally {
            Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
