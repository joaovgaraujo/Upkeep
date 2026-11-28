BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'steps\Setup-Helpers.ps1')
}

Describe 'Get-PinnedWinutil' {
    It 'refuses a copy whose hash does not match' {
        $root = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Path "$root\vendor\winutil" -Force | Out-Null
        Set-Content "$root\vendor\winutil\winutil.ps1" 'Write-Output tampered'
        Set-Content "$root\vendor\winutil\pin.json" '{"Version":"1.0","Sha256":"00"}'
        { Get-PinnedWinutil -Root $root } | Should -Throw '*does not match*'
    }

    It 'refuses when the copy is missing' {
        $root = Join-Path $TestDrive 'missing'
        New-Item -ItemType Directory -Path "$root\vendor\winutil" -Force | Out-Null
        Set-Content "$root\vendor\winutil\pin.json" '{"Version":"1.0","Sha256":"00"}'
        { Get-PinnedWinutil -Root $root } | Should -Throw '*not found*'
    }
}

Describe 'Find-StoreDatabase' {
    It 'prefers store.db when it exists' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content "$dir\store.db" ''
        Set-Content "$dir\store-0123456789abcdef0123456789abcdef.db" ''
        Find-StoreDatabase -StoreState $dir | Should -Be "$dir\store.db"
    }

    It 'finds the versioned database and ignores look-alikes' {
        $dir = Join-Path $TestDrive 'versioned'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content "$dir\store-0123456789abcdef0123456789abcdef.db" ''
        Set-Content "$dir\store-backup.db" ''
        Set-Content "$dir\store-0123456789abcdef0123456789abcdef.db-wal" ''
        @(Find-StoreDatabase -StoreState $dir) | Should -Be @("$dir\store-0123456789abcdef0123456789abcdef.db")
    }

    It 'returns nothing when the Store was never opened' {
        @(Find-StoreDatabase -StoreState (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
}

Describe 'Set-StoreSearchBlocked' {
    It 'skips with a reason when there is no database' {
        $r = Set-StoreSearchBlocked -ReportDir $TestDrive -StoreState (Join-Path $TestDrive 'empty')
        $r.Status | Should -Be 'Skipped'
        $r.Detail | Should -Match 'found 0'
    }

    It 'blocks the database, keeps a backup, and does not back up twice' {
        $dir = Join-Path $TestDrive 'apply'
        $reports = Join-Path $TestDrive 'reports'
        New-Item -ItemType Directory -Path $dir, $reports | Out-Null
        $db = "$dir\store-0123456789abcdef0123456789abcdef.db"
        Set-Content $db 'x'
        try {
            $first = Set-StoreSearchBlocked -ReportDir $reports -StoreState $dir
            $first.Status | Should -Be 'Completed'
            "$reports\store-search-acl.txt" | Should -Exist
            Test-StoreSearchBlocked -Path $db | Should -BeTrue

            Remove-Item "$reports\store-search-acl.txt"
            $second = Set-StoreSearchBlocked -ReportDir $reports -StoreState $dir
            $second.Status | Should -Be 'OK'
            $second.Detail | Should -Match 'Already applied'
            "$reports\store-search-acl.txt" | Should -Not -Exist
        } finally {
            & icacls.exe $db /remove:d '*S-1-1-0' | Out-Null
        }
    }
}

Describe 'Smart App Control' {
    BeforeEach {
        $key = 'HKCU:\Software\UpkeepTests\CI-' + [guid]::NewGuid().ToString('N')
        New-Item -Path $key -Force | Out-Null
        $reports = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $reports | Out-Null
        $noCiTool = Join-Path $TestDrive 'no-citool.exe'
    }
    AfterEach { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads <Value> as <State>' -ForEach @(
        @{ Value = 0; State = 'Off' }
        @{ Value = 1; State = 'On' }
        @{ Value = 2; State = 'Evaluation' }
    ) {
        New-ItemProperty -Path $key -Name VerifiedAndReputablePolicyState -Value $Value -PropertyType DWord | Out-Null
        Get-SmartAppControlState -PolicyKey $key | Should -Be $State
    }

    It 'reports Unknown when the value is absent' {
        Get-SmartAppControlState -PolicyKey $key | Should -Be 'Unknown'
    }

    It 'turns it off and records the previous state' {
        New-ItemProperty -Path $key -Name VerifiedAndReputablePolicyState -Value 1 -PropertyType DWord | Out-Null
        $r = Disable-SmartAppControl -ReportDir $reports -PolicyKey $key -CiTool $noCiTool -GetEnforced { 'Off' }
        $r.Status | Should -Be 'OK'
        $r.RestartNeeded | Should -BeFalse
        Get-SmartAppControlState -PolicyKey $key | Should -Be 'Off'
        (Get-Content "$reports\smart-app-control-before.json" -Raw | ConvertFrom-Json).Before | Should -Be 'On'
    }

    It 'asks for a restart when Windows still enforces it' {
        New-ItemProperty -Path $key -Name VerifiedAndReputablePolicyState -Value 2 -PropertyType DWord | Out-Null
        $r = Disable-SmartAppControl -ReportDir $reports -PolicyKey $key -CiTool $noCiTool -GetEnforced { 'On' }
        $r.Status | Should -Be 'Warning'
        $r.RestartNeeded | Should -BeTrue
        $r.Detail | Should -Match 'restart'
    }

    It 'changes nothing when it is already off' {
        New-ItemProperty -Path $key -Name VerifiedAndReputablePolicyState -Value 0 -PropertyType DWord | Out-Null
        $r = Disable-SmartAppControl -ReportDir $reports -PolicyKey $key -CiTool $noCiTool -GetEnforced { throw 'not called' }
        $r.Status | Should -Be 'OK'
        "$reports\smart-app-control-before.json" | Should -Not -Exist
    }

    It 'skips on Windows without Smart App Control' {
        $r = Disable-SmartAppControl -ReportDir $reports -PolicyKey $key -CiTool $noCiTool
        $r.Status | Should -Be 'Skipped'
    }
}

Describe 'Setup-NewPC.ps1 wiring' {
    BeforeAll { $setup = Get-Content -LiteralPath (Join-Path $repo 'Setup-NewPC.ps1') -Raw }

    It 'does not download winutil at run time' {
        $setup | Should -Not -Match 'christitus\.com'
        $setup | Should -Match 'Get-PinnedWinutil'
    }

    It 'passes -DisableSmartAppControl through elevation and resume' {
        $setup | Should -Match "if \(\`$DisableSmartAppControl\) \{ \`$argList \+= '-DisableSmartAppControl' \}"
    }

    It 'ships the pinned winutil in the installer, the portable build and the resume snapshot' {
        Get-Content (Join-Path $repo 'installer\Upkeep.iss') -Raw | Should -Match ([regex]::Escape('vendor\winutil\*'))
        Get-Content (Join-Path $repo 'Build-Portable.ps1') -Raw | Should -Match ([regex]::Escape('vendor\winutil\*'))
        Get-Content (Join-Path $repo 'steps\Setup-Resume.ps1') -Raw | Should -Match ([regex]::Escape('vendor\winutil'))
    }
}
