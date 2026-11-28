BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'steps\WingetOwnership.ps1')

    # The prefetch helpers are a script block inside Update-WingetApps.ps1.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'steps\Update-WingetApps.ps1'), [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:prefetchHelpers' }, $true)
    . ([scriptblock]::Create($assign.Right.Extent.Text.Trim().TrimStart('{').TrimEnd('}')))

    $sample = @(
        '   - ',
        'Name                         Id                       Version      Available  Source',
        '-----------------------------------------------------------------------------------',
        'topgrade                     topgrade-rs.topgrade     17.17.0      17.18.0    winget',
        'Tailscale                    Tailscale.Tailscale      1.90.0                  winget',
        'Some Long Name That Is Cut…  Publisher.Truncated…     1.0                     winget',
        'uv                           astral-sh.uv             0.9.1                   winget',
        'Windows Subsystem for Linux  Microsoft.WSL            2.6.1.0                 winget'
    )
}

Describe 'ConvertFrom-WingetList' {
    It 'reads the ids and drops truncated ones' {
        $ids = ConvertFrom-WingetList -Lines $sample
        $ids | Should -Contain 'topgrade-rs.topgrade'
        $ids | Should -Contain 'Tailscale.Tailscale'
        $ids | Should -Contain 'astral-sh.uv'
        $ids | Should -Contain 'Microsoft.WSL'
        $ids | Should -Not -Contain 'Publisher.Truncated…'
        $ids.Count | Should -Be 4
    }

    It 'returns nothing without a table' {
        @(ConvertFrom-WingetList -Lines @('No installed package found matching input criteria.')).Count | Should -Be 0
    }
}

Describe 'Get-WingetTrackedIds' {
    It 'parses the listing and keeps it for the next run' {
        $list = Join-Path $TestDrive 'list.txt'
        $kept = Join-Path $TestDrive 'tracked.json'
        Set-Content -LiteralPath $list -Value $sample -Encoding UTF8
        @(Get-WingetTrackedIds -ListPath $list -TrackedPath $kept -WaitSec 0).Count | Should -Be 4
        @((Get-Content $kept -Raw | ConvertFrom-Json)).Count | Should -Be 4
    }

    It 'falls back to the kept list when this run did not list' {
        $kept = Join-Path $TestDrive 'kept.json'
        '["Tailscale.Tailscale"]' | Set-Content -LiteralPath $kept
        @(Get-WingetTrackedIds -ListPath (Join-Path $TestDrive 'none.txt') -TrackedPath $kept -WaitSec 0) | Should -Be @('Tailscale.Tailscale')
    }
}

Describe 'Get-TopgradeOwnedSteps' {
    It 'skips the steps whose binary winget installed' {
        $steps = @(Get-TopgradeOwnedSteps -Tracked (ConvertFrom-WingetList -Lines $sample) -ChocoLib '')
        @($steps.Step) | Should -Be @('self_update', 'tailscale', 'wsl_update', 'uv')
    }

    It 'keeps every step when winget tracks none of those apps' {
        @(Get-TopgradeOwnedSteps -Tracked @('7zip.7zip') -ChocoLib '').Count | Should -Be 0
    }

    It 'skips self_update when Chocolatey installed topgrade' {
        $lib = Join-Path $TestDrive 'lib'
        New-Item -ItemType Directory -Path (Join-Path $lib 'topgrade') -Force | Out-Null
        (@(Get-TopgradeOwnedSteps -Tracked @() -ChocoLib $lib))[0].Owner | Should -Be 'Chocolatey (topgrade)'
    }
}

Describe 'Prefetch stall check' {
    BeforeEach {
        $script:prefetchSeen = @{}
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$root\Pkg.Id" -Force | Out-Null
        Set-Content "$root\Pkg.Id.started" ''
        (Get-Item "$root\Pkg.Id.started").LastWriteTime = (Get-Date).AddSeconds(-600)
    }

    It 'does not stop a download that keeps growing' {
        $f = "$root\Pkg.Id\setup.exe"
        [IO.File]::WriteAllBytes($f, (New-Object byte[] 10))
        Test-PrefetchStalled -Root $root -Id 'Pkg.Id' -StallSec 2 | Should -BeTrue -Because 'nothing has arrived in the 10 minutes since it started'
        $script:prefetchSeen['Pkg.Id'].Checked = (Get-Date).AddSeconds(-10)
        [IO.File]::WriteAllBytes($f, (New-Object byte[] 5000))
        Test-PrefetchStalled -Root $root -Id 'Pkg.Id' -StallSec 2 | Should -BeFalse
    }

    It 'stops one that has not grown for the stall time' {
        Test-PrefetchStalled -Root $root -Id 'Pkg.Id' -StallSec 2 | Should -BeTrue
    }

    It 'stops any download after the hard limit' {
        $script:prefetchSeen['Pkg.Id'] = [pscustomobject]@{ Bytes = 0; Grew = Get-Date; Checked = Get-Date }
        Test-PrefetchStalled -Root $root -Id 'Pkg.Id' -StallSec 600 -MaxSec 300 | Should -BeTrue
    }

    It 'counts bytes in the download folder' {
        [IO.File]::WriteAllBytes("$root\Pkg.Id\a.bin", (New-Object byte[] 1234))
        Get-PrefetchBytes -Root $root -Id 'Pkg.Id' | Should -BeGreaterOrEqual 1234
    }
}

Describe 'Topgrade config' {
    It 'never runs topgrade''s codex step (Update-AiClis.ps1 owns Codex)' {
        $bat = Get-Content (Join-Path $repo 'SystemUpdate_Topgrade.bat') -Raw
        @([regex]::Matches($bat, 'echo disable = \[[^\]]*"codex"')).Count | Should -Be 2
    }

    It 'does not run tailscale alongside winget' {
        Get-Content (Join-Path $repo 'steps\Update-WingetApps.ps1') -Raw | Should -Not -Match "'tailscale' = '"
    }
}
