BeforeAll {
    . "$PSScriptRoot\..\steps\Manage-EngineLock.ps1"
    $caller = [pscustomobject]@{ ProcessId = 1234; CreationDate = [datetime]'2026-09-16T10:00:00Z' }
}
Describe 'Engine lock recovery without running updates' {
    BeforeEach {
        $lockPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Mock Get-CimInstance { $null }
    }
    It 'acquires a new lock and releases only its own record' {
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
        Test-Path "$lockPath\owner.json" | Should -BeTrue
        Invoke-EngineLock Release $lockPath $caller | Should -Be 0
        Test-Path $lockPath | Should -BeFalse
    }
    It 'recovers a fresh legacy folder without waiting three hours or rebooting' {
        New-Item $lockPath -ItemType Directory | Out-Null
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
    }
    It 'recovers a dead owner immediately' {
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
    }
    It 'does not expire a live owner even when its folder is old' {
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
        (Get-Item $lockPath).CreationTime = (Get-Date).AddDays(-2)
        Mock Get-CimInstance { $caller } -ParameterFilter { $Filter -eq 'ProcessId = 1234' }
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 2
    }
    It 'recovers when Windows has reused the saved PID' {
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
        Mock Get-CimInstance {
            [pscustomobject]@{ ProcessId = 1234; CreationDate = [datetime]'2026-09-16T11:00:00Z' }
        } -ParameterFilter { $Filter -eq 'ProcessId = 1234' }
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
    }
    It 'protects an active older engine with no ownership record' {
        New-Item $lockPath -ItemType Directory | Out-Null
        Mock Get-CimInstance {
            [pscustomobject]@{ ProcessId = 5678; CommandLine = 'cmd /c "C:\Program Files\Upkeep\SystemUpdate_Topgrade.bat"' }
        } -ParameterFilter { $Filter -eq "Name = 'cmd.exe'" }
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 2
    }
    It 'recovers an interrupted ownership write' {
        New-Item $lockPath -ItemType Directory | Out-Null
        Set-Content "$lockPath\owner.json" '{broken'
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
    }
    It 'does not release another owner or delete unrelated files' {
        Invoke-EngineLock Acquire $lockPath $caller | Should -Be 0
        $other = [pscustomobject]@{ ProcessId = 5678; CreationDate = $caller.CreationDate }
        Invoke-EngineLock Release $lockPath $other | Should -Be 0
        Test-Path "$lockPath\owner.json" | Should -BeTrue
        Set-Content "$lockPath\keep.txt" 'keep'
        Invoke-EngineLock Release $lockPath $caller | Should -Be 0
        Test-Path "$lockPath\keep.txt" | Should -BeTrue
    }
    It 'fails closed if process inspection is unavailable' {
        Mock Get-CimInstance { throw 'CIM unavailable' }
        { Invoke-EngineLock Acquire $lockPath $caller } | Should -Throw '*CIM unavailable*'
        Test-Path "$lockPath\owner.json" | Should -BeFalse
    }
    It 'works through cmd.exe, rejects a second live caller, and recovers after the first exits without releasing' {
        $case = Join-Path $TestDrive "handoff with space's"
        New-Item $case -ItemType Directory | Out-Null
        $helperPath = [IO.Path]::GetFullPath("$PSScriptRoot\..\steps\Manage-EngineLock.ps1")
        $batch = Join-Path $case 'fixture.cmd'
        $integrationLock = Join-Path $case 'engine.lock'
        @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$helperPath" -LockDirectory "$integrationLock"
set "result=%errorlevel%"
>"%~1" echo %result%
if not "%result%"=="0" exit /b %result%
if "%~2"=="hold" powershell.exe -NoProfile -Command "Start-Sleep -Seconds 20"
exit /b 0
"@ | Set-Content -LiteralPath $batch -Encoding ASCII
        $first = $null
        try {
            $first = Start-Process cmd.exe -ArgumentList "/d /c `"`"$batch`" `"$case\first.txt`" hold`"" -WindowStyle Hidden -PassThru
            $deadline = (Get-Date).AddSeconds(15)
            while ((-not (Test-Path "$case\first.txt") -or (Get-Item "$case\first.txt").Length -eq 0) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            (Get-Content "$case\first.txt").Trim() | Should -Be '0'
            & cmd.exe /d /c "`"$batch`" `"$case\second.txt`""
            $LASTEXITCODE | Should -Be 2
            & taskkill.exe /PID $first.Id /T /F | Out-Null
            $first.WaitForExit(5000) | Should -BeTrue
            & cmd.exe /d /c "`"$batch`" `"$case\third.txt`""
            $LASTEXITCODE | Should -Be 0
            (Get-Content "$case\third.txt").Trim() | Should -Be '0'
        } finally {
            if ($first -and -not $first.HasExited) { & taskkill.exe /PID $first.Id /T /F | Out-Null }
        }
    }
}
