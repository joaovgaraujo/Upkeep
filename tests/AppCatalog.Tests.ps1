BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $catalog = Get-Content -LiteralPath (Join-Path $repo 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $apps = @($catalog.PSObject.Properties)
    # Categories gui/src/i18n.rs translates; a new one needs a translation there.
    $i18n = Get-Content -LiteralPath (Join-Path $repo 'gui\src\i18n.rs') -Raw
    $start = $i18n.IndexOf('pub fn category_display')
    $body = $i18n.Substring($start, $i18n.IndexOf('other => other', $start) - $start)
    $known = @([regex]::Matches($body, '"([^"]+)" =>') | ForEach-Object { $_.Groups[1].Value })
}

Describe 'apps.json' {
    It 'has every field on every entry' {
        $bad = foreach ($a in $apps) {
            foreach ($f in 'content', 'category', 'winget', 'choco', 'description', 'description_pt') {
                if (-not [string]$a.Value.$f) { "$($a.Name).$f" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'can install every entry from at least one source' {
        @($apps | Where-Object { $_.Value.winget -eq 'na' -and $_.Value.choco -eq 'na' } | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'uses only categories the GUI translates' {
        @($apps | Where-Object { $known -notcontains $_.Value.category } | ForEach-Object { "$($_.Name): $($_.Value.category)" }) | Should -BeNullOrEmpty
    }

    It 'lists each winget ID once' {
        $dupes = $apps | Where-Object { $_.Value.winget -ne 'na' } | Group-Object { ([string]$_.Value.winget).ToLowerInvariant() } | Where-Object Count -gt 1
        @($dupes | ForEach-Object { "$($_.Name): $(($_.Group | ForEach-Object Name) -join ', ')" }) | Should -BeNullOrEmpty
    }

    It 'has the AI coding tools' -ForEach @(
        @{ Key = 'claude-code'; Winget = 'Anthropic.ClaudeCode' }
        @{ Key = 'codex'; Winget = 'OpenAI.Codex' }
        @{ Key = 'antigravity'; Winget = 'Google.AntigravityIDE' }
    ) {
        $catalog.$Key.winget | Should -Be $Winget
    }
}

Describe 'Presets' {
    It '<_> only names apps in the catalog' -ForEach @('new-pc-basic', 'dev-machine', 'full') {
        $preset = @((Get-Content -LiteralPath (Join-Path $repo "presets\$_.json") -Raw | ConvertFrom-Json))
        @($preset | Where-Object { -not $catalog.PSObject.Properties[$_] }) | Should -BeNullOrEmpty
    }

    It 'new-pc-basic.optional names catalog apps that the pack does not already tick' {
        $optional = @((Get-Content -LiteralPath (Join-Path $repo 'presets\new-pc-basic.optional.json') -Raw | ConvertFrom-Json))
        $basic = @((Get-Content -LiteralPath (Join-Path $repo 'presets\new-pc-basic.json') -Raw | ConvertFrom-Json))
        $optional | Should -Not -BeNullOrEmpty
        @($optional | Where-Object { -not $catalog.PSObject.Properties[$_] }) | Should -BeNullOrEmpty
        @($optional | Where-Object { $basic -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'dev-machine installs Claude Code' {
        @((Get-Content -LiteralPath (Join-Path $repo 'presets\dev-machine.json') -Raw | ConvertFrom-Json)) | Should -Contain 'claude-code'
    }
}
