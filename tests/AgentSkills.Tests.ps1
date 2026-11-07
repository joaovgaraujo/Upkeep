BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # A source repo with one skill folder, as a local git repository.
    function New-SkillRepo {
        param([string]$Dir, [string]$Body = 'v1')
        # CI stops on any stderr line; git's line-ending warning is one.
        $ErrorActionPreference = 'Continue'
        New-Item "$Dir\my-skill" -ItemType Directory -Force | Out-Null
        "---`nname: my-skill`ndescription: test`n---`n$Body" | Set-Content "$Dir\my-skill\SKILL.md"
        git -C $Dir -c core.autocrlf=false init -q -b main 2>&1 | Out-Null
        git -C $Dir -c core.autocrlf=false add -A 2>&1 | Out-Null
        git -C $Dir -c core.autocrlf=false -c user.name=t -c user.email=t@t commit -q -m init 2>&1 | Out-Null
    }
    function Update-SkillRepo {
        param([string]$Dir, [string]$Body)
        $ErrorActionPreference = 'Continue'
        "---`nname: my-skill`ndescription: test`n---`n$Body" | Set-Content "$Dir\my-skill\SKILL.md"
        git -C $Dir -c core.autocrlf=false -c user.name=t -c user.email=t@t commit -q -am update 2>&1 | Out-Null
    }
    # Runs the step with -File in Windows PowerShell 5.1, as the engine does,
    # against scratch skills/settings/state folders. -AsUser: CI is elevated.
    function Invoke-Skills {
        param([string]$Case, [string]$Settings, [string]$Extra = '')
        $Settings | Set-Content "$Case\settings.json"
        '{}' | Set-Content "$Case\catalog.json"
        $old = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = "$Case\local"
            $out = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$repoRoot\steps\Update-AgentSkills.ps1" -AsUser `
                -SettingsPath "$Case\settings.json" -CatalogPath "$Case\catalog.json" -SkillsDir "$Case\skills" $Extra 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally { $env:LOCALAPPDATA = $old }
        [pscustomobject]@{ Code = $code; Output = $out }
    }
}

Describe 'Agent skills synced from a git repository' {
    BeforeEach {
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item "$case\skills" -ItemType Directory -Force | Out-Null
        New-SkillRepo "$case\src"
        $url = 'file:///' + ("$case\src" -replace '\\', '/')
        $settings = '{"AgentSkillRepos":["' + $url + '"]}'
    }
    It 'installs a skill from the repo when it is missing' {
        $r = Invoke-Skills $case $settings
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'my-skill: installed from'
        Get-Content "$case\skills\my-skill\SKILL.md" -Raw | Should -Match 'v1'
    }
    It 'updates an unedited skill when the repo changes' {
        (Invoke-Skills $case $settings).Code | Should -Be 0
        Update-SkillRepo "$case\src" 'v2'
        $r = Invoke-Skills $case $settings
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'my-skill: updated from'
        Get-Content "$case\skills\my-skill\SKILL.md" -Raw | Should -Match 'v2'
    }
    It 'leaves a locally edited skill alone and lists it' {
        (Invoke-Skills $case $settings).Code | Should -Be 0
        Add-Content "$case\skills\my-skill\SKILL.md" 'my local edit'
        Update-SkillRepo "$case\src" 'v2'
        $r = Invoke-Skills $case $settings
        $r.Code | Should -Be 3
        Get-Content "$case\skills\my-skill\SKILL.md" -Raw | Should -Match 'my local edit'
        $report = Get-Content "$case\local\Upkeep\Reports\manual-updates-skills.json" -Raw | ConvertFrom-Json
        $report.Reason | Should -Match 'edited here'
    }
    It 'backs up a hand-copied skill the first time it takes it over' {
        New-Item "$case\skills\my-skill" -ItemType Directory -Force | Out-Null
        "---`nname: my-skill`n---`nold hand copy" | Set-Content "$case\skills\my-skill\SKILL.md"
        $r = Invoke-Skills $case $settings
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'first update from there; old copy'
        @(Get-ChildItem "$case\local\Upkeep\Backups\skills" -Directory).Count | Should -Be 1
    }
    It 'does not touch a skill set to keep' {
        (Invoke-Skills $case $settings).Code | Should -Be 0
        Update-SkillRepo "$case\src" 'v2'
        $keep = $settings.TrimEnd('}') + ',"AgentSkillKeep":["my-skill"]}'
        $r = Invoke-Skills $case $keep
        $r.Output | Should -Match 'kept as is'
        Get-Content "$case\skills\my-skill\SKILL.md" -Raw | Should -Match 'v1'
    }
    It 'lists skills and their source as JSON without changing anything' {
        (Invoke-Skills $case $settings).Code | Should -Be 0
        $src = '{"AgentSkillSources":{"my-skill":{"type":"git","url":"https://example.org/me/skills.git","path":"my-skill"}},"AgentSkillKeep":["my-skill"]}'
        $r = Invoke-Skills $case $src '-Detect'
        $r.Code | Should -Be 0
        $json = @($r.Output | ConvertFrom-Json)
        $json[0].Name | Should -Be 'my-skill'
        $json[0].Source | Should -Be 'example.org/me/skills/my-skill'
        $json[0].Keep | Should -BeTrue
    }
}

Describe 'G HUB updater step' {
    It 'skips when G HUB is not installed' {
        $out = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$repoRoot\steps\Update-GHub.ps1" -ServiceName 'Upkeep_NoSuchService_Test' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'not installed'
    }
}
