Describe 'SSH relay runner' {
    It 'runs an engine whose path has spaces and passes back its output and exit code' {
        # The installed engine lives under "C:\Program Files"; 1.9.0 split that
        # path at the space and never started the run.
        $dir = Join-Path $TestDrive 'Program Files\Up keep'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $bat = Join-Path $dir 'SystemUpdate_Topgrade.bat'
        Set-Content $bat -Encoding Ascii -Value @('@echo engine ran', '@exit /b 3')
        $work = Join-Path $TestDrive 'relay work'
        $runner = Join-Path $work 'run.ps1'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\steps\Invoke-InDesktop.ps1" -BatPath $bat -WriteRunnerOnly $runner
        $LASTEXITCODE | Should -Be 0
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner

        Get-Content (Join-Path $work 'out.txt') -Raw | Should -Match 'engine ran'
        (Get-Content (Join-Path $work 'done.txt') -Raw).Trim() | Should -Be '3'
    }
}
