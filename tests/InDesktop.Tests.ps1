Describe 'SSH relay, desktop side' {
    BeforeAll {
        $script = "$PSScriptRoot\..\steps\Invoke-InDesktop.ps1"
        # A fake engine in a folder with spaces, like C:\Program Files\Upkeep.
        function New-FakeEngine {
            param([string[]]$Lines)
            $dir = Join-Path $TestDrive "Program Files\Up keep $([guid]::NewGuid().ToString('N').Substring(0, 6))"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $bat = Join-Path $dir 'SystemUpdate_Topgrade.bat'
            Set-Content $bat -Encoding Ascii -Value $Lines
            $bat
        }
    }
    It 'runs an engine whose path has spaces and passes back its output and exit code' {
        $bat = New-FakeEngine @('@echo engine ran', '@exit /b 3')
        $work = Join-Path $TestDrive 'relay work'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $runner = Join-Path $work 'run.ps1'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -BatPath $bat -WorkDir $work -WriteRunnerOnly $runner
        $LASTEXITCODE | Should -Be 0
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner

        Get-Content (Join-Path $work 'out.txt') -Raw | Should -Match 'engine ran'
        (Get-Content (Join-Path $work 'engine_done.txt') -Raw).Trim() | Should -Be '3'
    }
    It 'hands the output over as numbered chunks of whole lines, then the exit code' {
        $bat = New-FakeEngine @(
            '@echo first line'
            '@echo setting %UPKEEP_FIXTURE% in desktop %UPKEEP_IN_DESKTOP%'
            '@powershell -NoProfile -Command "Start-Sleep -Seconds 2"'
            '@echo last line'
            '@exit /b 5')
        $work = Join-Path $TestDrive 'relay chunks'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        # What the SSH side writes with `set UPKEEP_`.
        Set-Content (Join-Path $work 'env.txt') -Encoding Ascii -Value 'UPKEEP_FIXTURE=it''s passed'

        $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -BatPath `"$bat`" -WorkDir `"$work`""
        $p.WaitForExit(60000) | Should -BeTrue

        Test-Path (Join-Path $work 'started.txt') | Should -BeTrue
        (Get-Content (Join-Path $work 'done.txt') -Raw).Trim() | Should -Be '5'
        $chunks = @(Get-ChildItem $work -Filter 'chunk_*.txt' | Sort-Object { [int]($_.BaseName -replace '\D') })
        $chunks.Count | Should -BeGreaterThan 1
        Get-ChildItem $work -Filter '*.tmp' | Should -BeNullOrEmpty
        $text = ($chunks | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
        $text | Should -Match "(?s)first line.*setting it's passed in desktop 1.*last line"
        $text | Should -Not -Match ([char]0xFEFF)
        foreach ($c in $chunks) { [IO.File]::ReadAllText($c.FullName) | Should -Match "`n$" }
    }
}
