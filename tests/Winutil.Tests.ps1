BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'steps\Setup-Helpers.ps1')
    $pinned = Get-PinnedWinutil -Root $repo
    $source = Get-Content -LiteralPath $pinned.Path -Raw

    # winutil embeds its catalogs as here-strings piped to ConvertFrom-Json.
    function Get-WinutilBlock([string]$Name) {
        $m = [regex]::Match($source, '(?s)\$sync\.configs\.' + $Name + ' = @''\r?\n(.*?)\r?\n''@ \| ConvertFrom-Json')
        if (-not $m.Success) { throw "winutil block '$Name' not found" }
        $m.Groups[1].Value | ConvertFrom-Json
    }
    $tweaks = Get-WinutilBlock 'tweaks'
    $appx = Get-WinutilBlock 'appx'

    # Every winutil ID Upkeep can put in a -Config file.
    $optimize = Get-Content -LiteralPath (Join-Path $repo 'gui\src\optimize.rs') -Raw
    $usedIds = @([regex]::Matches($optimize, '"(WPF[A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    # Parenthesized: PS 5.1's ConvertFrom-Json emits a JSON array as one object.
    $usedIds += @((Get-Content -LiteralPath (Join-Path $repo 'presets\winutil-newpc.json') -Raw | ConvertFrom-Json))
    $usedIds = @($usedIds | Select-Object -Unique)

    # Setup-NewPC.ps1 definitions, read without running the script.
    $setupAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Setup-NewPC.ps1'), [ref]$null, [ref]$null)
    function Get-SetupValue([string]$Variable) {
        $assign = $setupAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Variable }, $true)
        Invoke-Expression $assign.Right.Extent.Text
    }
    $toggleDefs = Get-SetupValue '$toggleDefs'
    $servicingEntries = Get-SetupValue '$servicingEntries'
}

Describe 'Pinned winutil' {
    It 'matches the SHA-256 in pin.json' {
        $pinned.Sha256 | Should -Match '^[0-9A-F]{64}$'
    }

    It 'is the version pin.json names' {
        $source | Should -Match ('\$sync\.version = "' + [regex]::Escape($pinned.Version) + '"')
    }

    It 'has a licence file next to it' {
        Join-Path $repo 'vendor\winutil\LICENSE' | Should -Exist
    }

    It 'still knows every winutil ID Upkeep uses (<_>)' -ForEach @(
        & {
            $r = Split-Path $PSScriptRoot -Parent
            $o = Get-Content -LiteralPath (Join-Path $r 'gui\src\optimize.rs') -Raw
            @([regex]::Matches($o, '"(WPF[A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value }) +
                @((Get-Content -LiteralPath (Join-Path $r 'presets\winutil-newpc.json') -Raw | ConvertFrom-Json)) |
                Select-Object -Unique
        }
    ) {
        ($null -ne $tweaks.$_ -or $null -ne $appx.$_) | Should -BeTrue
    }

    It 'lists every used tweak that goes through Windows servicing as deferrable' {
        # These queue forever while a restart is pending, so Setup-NewPC.ps1
        # must hand them to the after-restart task.
        $needServicing = @($usedIds | Where-Object {
                $entry = $tweaks.$_
                $entry -and (($entry | ConvertTo-Json -Depth 10) -match '(?i)\bdism|WindowsOptionalFeature|WindowsCapability')
            })
        $missing = @($needServicing | Where-Object { $servicingEntries -notcontains $_ -and $_ -notlike 'WPFFeature*' })
        $missing | Should -BeNullOrEmpty
    }

    It 'still runs the Store search tweak against store.db only' {
        # Setup-Helpers.ps1 replaces it because current Store builds use
        # store-<hash>.db. If upstream starts handling that, drop ours.
        ($tweaks.WPFTweaksDisableStoreSearch | ConvertTo-Json -Depth 10) | Should -Match 'store\.db'
    }

    It 'still prints the headless summary line Setup-NewPC.ps1 looks for' {
        $source | Should -Match ([regex]::Escape('"Completed with warnings. See '))
    }
}

Describe 'Registry toggles mirror winutil' {
    # slug -> winutil toggle, and whether Upkeep's value is winutil's "on"
    # value (Value) or its "off" value (OriginalValue).
    It '<Slug> matches <Toggle>' -ForEach @(
        @{ Slug = 'dark-theme'; Toggle = 'WPFToggleDarkMode'; Field = 'Value' }
        @{ Slug = 'file-extensions'; Toggle = 'WPFToggleShowExt'; Field = 'Value' }
        @{ Slug = 'hidden-files'; Toggle = 'WPFToggleHiddenFiles'; Field = 'Value' }
        @{ Slug = 'mouse-accel-off'; Toggle = 'WPFToggleMouseAcceleration'; Field = 'OriginalValue' }
        @{ Slug = 'num-lock'; Toggle = 'WPFToggleNumLock'; Field = 'Value' }
        @{ Slug = 'sticky-keys-off'; Toggle = 'WPFToggleStickyKeys'; Field = 'OriginalValue' }
        @{ Slug = 'verbose-bsod'; Toggle = 'WPFToggleDetailedBSoD'; Field = 'Value' }
        @{ Slug = 'long-paths'; Toggle = 'WPFToggleLongPaths'; Field = 'Value' }
    ) {
        $upstream = @($tweaks.$Toggle.registry)
        $upstream.Count | Should -BeGreaterThan 0
        $ours = @($toggleDefs[$Slug])
        $ours.Count | Should -Be $upstream.Count
        foreach ($u in $upstream) {
            $path = ([string]$u.Path) -replace '^HKU:\\\.Default', 'Registry::HKEY_USERS\.DEFAULT'
            $match = @($ours | Where-Object { $_.Path -eq $path -and $_.Name -eq $u.Name })
            $match.Count | Should -Be 1 -Because "$Slug should set $path\$($u.Name)"
            [string]$match[0].Value | Should -Be ([string]$u.$Field)
        }
    }
}
