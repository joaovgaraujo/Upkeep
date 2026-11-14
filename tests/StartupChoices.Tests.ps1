BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script:testKey = 'HKCU:\Software\UpkeepTest\StartupChoices'
    function Invoke-Restore([string]$Json) {
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $case -ItemType Directory | Out-Null
        $path = Join-Path $case 'startup-choices.json'
        if ($Json) { Set-Content -LiteralPath $path -Value $Json -Encoding UTF8 }
        $out = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$repoRoot\steps\Restore-StartupChoices.ps1" -ChoicesPath $path 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    }
    # A StartupApproved-style value under a test key (an unknown key layout,
    # so the step trusts the recorded choice instead of looking for the item).
    function Set-Approved([byte]$First) {
        New-Item -Path $script:testKey -Force | Out-Null
        New-ItemProperty -Path $script:testKey -Name 'Fixture Tool' -Value ([byte[]]@($First, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -PropertyType Binary -Force | Out-Null
    }
    $script:choice = '{"startup":[{"name":"Fixture Tool","approved_key":"HKCU:\\Software\\UpkeepTest\\StartupChoices","approved_name":"Fixture Tool"}],' +
        '"tasks":[{"path":"\\","name":"Upkeep Fixture Task That Does Not Exist"}],' +
        '"services":[{"name":"UpkeepFixtureServiceThatDoesNotExist","start_mode":"Manual"}]}'
}
AfterAll { Remove-Item 'HKCU:\Software\UpkeepTest' -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Startup choices kept after updates' {
    It 'does nothing when no choices were recorded' {
        (Invoke-Restore '').Code | Should -Be 2
        (Invoke-Restore '{"startup":[],"tasks":[],"services":[]}').Code | Should -Be 2
    }
    It 'turns a startup item back off when an update turned it on' {
        Set-Approved 2
        $r = Invoke-Restore $script:choice
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Fixture Tool: an update turned it back on - off again'
        $r.Output | Should -Match 'Put back 1 of the 3'
        $v = (Get-ItemProperty -Path $script:testKey -Name 'Fixture Tool').'Fixture Tool'
        ($v[0] -band 1) | Should -Be 1
    }
    It 'leaves things alone when they are still as chosen, and skips items that are gone' {
        Set-Approved 3
        $r = Invoke-Restore $script:choice
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'All 3 startup choice\(s\) you made in Upkeep are still in place'
        $r.Output | Should -Not -Match 'off again'
    }
    It 'reads a file written with a BOM' {
        Set-Approved 2
        $case = Join-Path $TestDrive 'bom'
        New-Item $case -ItemType Directory -Force | Out-Null
        $path = Join-Path $case 'startup-choices.json'
        [IO.File]::WriteAllText($path, $script:choice, (New-Object Text.UTF8Encoding($true)))
        $out = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$repoRoot\steps\Restore-StartupChoices.ps1" -ChoicesPath $path 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'off again'
    }
}
