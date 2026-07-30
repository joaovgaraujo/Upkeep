# Functions.Tests.ps1
# Pester 5.x test scaffold for pure logic functions.

BeforeAll {
    . "$PSScriptRoot\..\Functions.ps1"
}

Describe 'ConvertTo-SkipFlags' -Tag 'Property' {
    # Feature: update-dashboard, Property 1: Category selection produces correct skip flags
    # Validates: Requirements 1.3, 1.4, 1.5

    BeforeAll {
        function Assert-SkipFlags {
            param(
                [bool]$WindowsUpdate,
                [bool]$Store,
                [bool]$Apps,
                [bool]$Drivers
            )

            $categories = @{
                WindowsUpdate = $WindowsUpdate
                Store         = $Store
                Apps          = $Apps
                Drivers       = $Drivers
            }

            $result = ConvertTo-SkipFlags -Categories $categories

            # DASHBOARD_SKIP_WINUPDATE = "1" iff WindowsUpdate is unchecked
            if (-not $WindowsUpdate) {
                $result['DASHBOARD_SKIP_WINUPDATE'] | Should -Be "1" -Because "WindowsUpdate is unchecked so skip flag should be '1'"
            } else {
                $result.ContainsKey('DASHBOARD_SKIP_WINUPDATE') | Should -BeFalse -Because "WindowsUpdate is checked so skip flag should not be present"
            }

            # DASHBOARD_SKIP_STORE = "1" iff Store is unchecked
            if (-not $Store) {
                $result['DASHBOARD_SKIP_STORE'] | Should -Be "1" -Because "Store is unchecked so skip flag should be '1'"
            } else {
                $result.ContainsKey('DASHBOARD_SKIP_STORE') | Should -BeFalse -Because "Store is checked so skip flag should not be present"
            }

            # DASHBOARD_SKIP_APPS = "1" iff Apps is unchecked
            if (-not $Apps) {
                $result['DASHBOARD_SKIP_APPS'] | Should -Be "1" -Because "Apps is unchecked so skip flag should be '1'"
            } else {
                $result.ContainsKey('DASHBOARD_SKIP_APPS') | Should -BeFalse -Because "Apps is checked so skip flag should not be present"
            }

            # InvokeEngine is $true iff at least one of {WindowsUpdate, Store, Apps} is checked
            $expectedInvoke = [bool]($WindowsUpdate -or $Store -or $Apps)
            $result['InvokeEngine'] | Should -Be $expectedInvoke -Because "InvokeEngine should be `$true iff at least one non-Drivers category is checked"
        }
    }

    It 'produces correct skip flags for all 16 subsets of categories' {
        # Enumerate all 2^4 = 16 combinations
        foreach ($mask in 0..15) {
            $wu   = [bool]($mask -band 1)
            $st   = [bool]($mask -band 2)
            $apps = [bool]($mask -band 4)
            $drv  = [bool]($mask -band 8)

            Assert-SkipFlags -WindowsUpdate $wu -Store $st -Apps $apps -Drivers $drv
        }
    }

    It 'produces correct skip flags for 100 random category combinations' {
        $rng = [System.Random]::new(42)  # Seeded for reproducibility

        foreach ($i in 1..100) {
            $wu   = [bool]$rng.Next(2)
            $st   = [bool]$rng.Next(2)
            $apps = [bool]$rng.Next(2)
            $drv  = [bool]$rng.Next(2)

            Assert-SkipFlags -WindowsUpdate $wu -Store $st -Apps $apps -Drivers $drv
        }
    }
}

Describe 'Add-LogLine' -Tag 'Property' {
    # Feature: update-dashboard, Property 2: Log buffer never exceeds maximum size
    # Validates: Requirements 2.1

    It 'Log buffer never exceeds maximum size (100 iterations, MaxLines=100)' {
        $rng = [System.Random]::new(42)
        $maxLines = 100

        for ($iter = 0; $iter -lt 100; $iter++) {
            $buffer = [System.Collections.Generic.List[string]]::new()
            $lineCount = $rng.Next(0, 501) # 0 to 500 lines per iteration for speed

            for ($i = 0; $i -lt $lineCount; $i++) {
                Add-LogLine -Buffer $buffer -Line "L${iter}_${i}" -MaxLines $maxLines
            }

            # Assert buffer never exceeds MaxLines
            $buffer.Count | Should -BeLessOrEqual $maxLines

            if ($lineCount -gt $maxLines) {
                # Buffer should contain exactly MaxLines entries (the most recent)
                $buffer.Count | Should -BeExactly $maxLines
                # Verify retained lines are the last MaxLines lines
                $expectedStart = $lineCount - $maxLines
                for ($j = 0; $j -lt $maxLines; $j++) {
                    $buffer[$j] | Should -BeExactly "L${iter}_$($expectedStart + $j)"
                }
            }
            elseif ($lineCount -gt 0) {
                # Buffer should contain all lines
                $buffer.Count | Should -BeExactly $lineCount
                $buffer[0] | Should -BeExactly "L${iter}_0"
                $buffer[$lineCount - 1] | Should -BeExactly "L${iter}_$($lineCount - 1)"
            }
            else {
                $buffer.Count | Should -BeExactly 0
            }
        }
    }

    It 'Log buffer respects default MaxLines=10000 for a large batch' {
        $buffer = [System.Collections.Generic.List[string]]::new()
        $lineCount = 15000

        for ($i = 0; $i -lt $lineCount; $i++) {
            Add-LogLine -Buffer $buffer -Line "BigLine_$i"
        }

        # Default MaxLines is 10000
        $buffer.Count | Should -BeLessOrEqual 10000
        $buffer.Count | Should -BeExactly 10000

        # Retained lines should be the last 10000
        $expectedStart = $lineCount - 10000
        $buffer[0] | Should -BeExactly "BigLine_$expectedStart"
        $buffer[9999] | Should -BeExactly "BigLine_$($lineCount - 1)"
    }

    It 'Lines are in correct order (most recent at end) across random batches' {
        $rng = [System.Random]::new(123)
        $buffer = [System.Collections.Generic.List[string]]::new()
        $maxLines = 100
        $allLines = [System.Collections.Generic.List[string]]::new()

        # Add lines in multiple batches to simulate streaming output
        $batchCount = $rng.Next(5, 20)
        for ($b = 0; $b -lt $batchCount; $b++) {
            $batchSize = $rng.Next(1, 200)
            for ($i = 0; $i -lt $batchSize; $i++) {
                $line = "B${b}_${i}"
                $allLines.Add($line)
                Add-LogLine -Buffer $buffer -Line $line -MaxLines $maxLines
            }

            # After every batch, buffer should not exceed MaxLines
            $buffer.Count | Should -BeLessOrEqual $maxLines
        }

        # Final verification: buffer contains the tail of allLines
        $expectedCount = [Math]::Min($allLines.Count, $maxLines)
        $buffer.Count | Should -BeExactly $expectedCount

        $startIndex = $allLines.Count - $expectedCount
        for ($j = 0; $j -lt $expectedCount; $j++) {
            $buffer[$j] | Should -BeExactly $allLines[$startIndex + $j]
        }
    }

    It 'Handles large N up to 20000 lines with MaxLines=100' {
        # Single test with a large line count to validate the 0-20000 range per the spec
        $buffer = [System.Collections.Generic.List[string]]::new()
        $maxLines = 100
        $lineCount = 20000

        for ($i = 0; $i -lt $lineCount; $i++) {
            Add-LogLine -Buffer $buffer -Line "XL_$i" -MaxLines $maxLines
        }

        $buffer.Count | Should -BeExactly $maxLines
        # Most recent lines retained
        $buffer[0] | Should -BeExactly "XL_$($lineCount - $maxLines)"
        $buffer[$maxLines - 1] | Should -BeExactly "XL_$($lineCount - 1)"
    }
}

Describe 'Start-UpdateEngine' {
    # Validates: Requirements 7.1, 7.3, 7.7

    It 'throws when engine path does not exist' {
        $skipFlags = @{ 'DASHBOARD_SKIP_WINUPDATE' = '1'; InvokeEngine = $true }
        { Start-UpdateEngine -SkipFlags $skipFlags -EnginePath 'C:\nonexistent\fake_engine.bat' } |
            Should -Throw '*not found*'
    }

    It 'sets DASHBOARD_SKIP_* environment variables from SkipFlags' {
        # Create a temp bat file that acts as a dummy engine
        $tempBat = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.bat'
        Set-Content -Path $tempBat -Value '@echo off & echo test'

        $skipFlags = @{
            'DASHBOARD_SKIP_WINUPDATE' = '1'
            'DASHBOARD_SKIP_STORE'     = '1'
            InvokeEngine               = $true
        }

        try {
            Mock Start-Process { [PSCustomObject]@{ Id = 9999; HasExited = $false } }

            Start-UpdateEngine -SkipFlags $skipFlags -EnginePath $tempBat

            # Verify env vars were set
            [System.Environment]::GetEnvironmentVariable('DASHBOARD_SKIP_WINUPDATE', 'Process') | Should -Be '1'
            [System.Environment]::GetEnvironmentVariable('DASHBOARD_SKIP_STORE', 'Process') | Should -Be '1'
        }
        finally {
            # Clean up env vars
            [System.Environment]::SetEnvironmentVariable('DASHBOARD_SKIP_WINUPDATE', $null, 'Process')
            [System.Environment]::SetEnvironmentVariable('DASHBOARD_SKIP_STORE', $null, 'Process')
            Remove-Item -Path $tempBat -ErrorAction SilentlyContinue
        }
    }

    It 'calls Start-Process with correct parameters and returns expected object' {
        $tempBat = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.bat'
        Set-Content -Path $tempBat -Value '@echo off & echo test'

        $skipFlags = @{ InvokeEngine = $true }

        try {
            $mockProcess = [PSCustomObject]@{ Id = 1234; HasExited = $false }
            Mock Start-Process { $mockProcess } -Verifiable

            $result = Start-UpdateEngine -SkipFlags $skipFlags -EnginePath $tempBat

            # Should have called Start-Process
            Should -InvokeVerifiable

            # Result should have Process, StdOutPath, StdErrPath
            $result.PSObject.Properties.Name | Should -Contain 'Process'
            $result.PSObject.Properties.Name | Should -Contain 'StdOutPath'
            $result.PSObject.Properties.Name | Should -Contain 'StdErrPath'

            # StdOutPath and StdErrPath should be file paths
            $result.StdOutPath | Should -Not -BeNullOrEmpty
            $result.StdErrPath | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tempBat -ErrorAction SilentlyContinue
        }
    }

    It 'does not set non-DASHBOARD_SKIP_ keys as env vars' {
        $tempBat = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.bat'
        Set-Content -Path $tempBat -Value '@echo off & echo test'

        $skipFlags = @{
            'DASHBOARD_SKIP_APPS' = '1'
            InvokeEngine          = $true
        }

        try {
            Mock Start-Process { [PSCustomObject]@{ Id = 5678; HasExited = $false } }

            Start-UpdateEngine -SkipFlags $skipFlags -EnginePath $tempBat

            # InvokeEngine should NOT be set as an env var
            [System.Environment]::GetEnvironmentVariable('InvokeEngine', 'Process') | Should -BeNullOrEmpty
            # But DASHBOARD_SKIP_APPS should be set
            [System.Environment]::GetEnvironmentVariable('DASHBOARD_SKIP_APPS', 'Process') | Should -Be '1'
        }
        finally {
            [System.Environment]::SetEnvironmentVariable('DASHBOARD_SKIP_APPS', $null, 'Process')
            Remove-Item -Path $tempBat -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-CategoryFromMarker' -Tag 'Property' {
    # Feature: update-dashboard, Property 3: Category marker classification is correct
    # **Validates: Requirements 2.3**

    BeforeAll {
        # Known marker-to-category mapping
        $script:MarkerMap = @{
            '[winget]'    = 'Apps'
            '[store]'     = 'Store'
            '[winupdate]' = 'WindowsUpdate'
            '[ea]'        = 'Apps'
            '[launch]'    = 'Apps'
        }
        # All known markers for injection
        $script:KnownMarkers = @('[winget]', '[store]', '[winupdate]', '[ea]', '[launch]')

        # Seeded RNG for reproducibility
        $script:Seed = 20240601
        $script:Rng = [System.Random]::new($script:Seed)

        function Get-RandomString {
            param([System.Random]$Rng, [int]$MinLen = 0, [int]$MaxLen = 80)
            $len = $Rng.Next($MinLen, $MaxLen + 1)
            $chars = [char[]]::new($len)
            for ($i = 0; $i -lt $len; $i++) {
                # Printable ASCII range 32-126, excluding '[' and ']' to avoid accidental markers
                do {
                    $c = [char]$Rng.Next(32, 127)
                } while ($c -eq '[' -or $c -eq ']')
                $chars[$i] = $c
            }
            return -join $chars
        }
    }

    It 'classifies known markers explicitly' {
        # Exact known-good mappings
        Get-CategoryFromMarker -Line 'Starting [winget] upgrade' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line 'Updating [store] apps' | Should -Be 'Store'
        Get-CategoryFromMarker -Line '[winupdate] checking for updates' | Should -Be 'WindowsUpdate'
        Get-CategoryFromMarker -Line 'Running [ea] guard' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line '[launch] starting apps' | Should -Be 'Apps'
    }

    It 'is case-insensitive for marker detection' {
        Get-CategoryFromMarker -Line 'test [WINGET] line' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line 'test [Store] line' | Should -Be 'Store'
        Get-CategoryFromMarker -Line 'test [WinUpdate] line' | Should -Be 'WindowsUpdate'
        Get-CategoryFromMarker -Line 'test [EA] line' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line 'test [LAUNCH] line' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line 'test [Winget] line' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line 'test [STORE] line' | Should -Be 'Store'
        Get-CategoryFromMarker -Line 'test [WINupdate] line' | Should -Be 'WindowsUpdate'
    }

    It 'handles edge cases: empty string, marker-only lines, marker at boundaries' {
        # Empty string — function requires non-empty via Mandatory, test with whitespace
        Get-CategoryFromMarker -Line ' ' | Should -Be $null

        # Line with only the marker
        Get-CategoryFromMarker -Line '[winget]' | Should -Be 'Apps'
        Get-CategoryFromMarker -Line '[store]' | Should -Be 'Store'
        Get-CategoryFromMarker -Line '[winupdate]' | Should -Be 'WindowsUpdate'

        # Marker at beginning
        Get-CategoryFromMarker -Line '[ea] something after' | Should -Be 'Apps'

        # Marker at end
        Get-CategoryFromMarker -Line 'something before [launch]' | Should -Be 'Apps'
    }

    It 'returns correct category for 100+ random strings with injected markers' {
        $iterations = 120
        for ($i = 0; $i -lt $iterations; $i++) {
            # Pick a random marker
            $markerIndex = $script:Rng.Next(0, $script:KnownMarkers.Count)
            $marker = $script:KnownMarkers[$markerIndex]
            $expectedCategory = $script:MarkerMap[$marker.ToLower()]

            # Generate random prefix/suffix (no brackets to avoid false markers)
            $prefix = Get-RandomString -Rng $script:Rng -MinLen 0 -MaxLen 40
            $suffix = Get-RandomString -Rng $script:Rng -MinLen 0 -MaxLen 40

            # Randomly vary marker case
            $caseVariant = switch ($script:Rng.Next(0, 3)) {
                0 { $marker.ToUpper() }
                1 { $marker.ToLower() }
                2 { $marker }  # original
            }

            $line = "$prefix$caseVariant$suffix"
            $result = Get-CategoryFromMarker -Line $line

            $result | Should -Be $expectedCategory -Because "Line '$line' contains marker '$marker' (case variant: '$caseVariant') which should map to '$expectedCategory'"
        }
    }

    It 'returns $null for 100+ random strings with no markers' {
        $iterations = 120
        for ($i = 0; $i -lt $iterations; $i++) {
            # Generate a random string that contains no recognized markers
            $line = Get-RandomString -Rng $script:Rng -MinLen 1 -MaxLen 80

            # The helper already avoids '[' and ']', so no marker can form
            $result = Get-CategoryFromMarker -Line $line

            $result | Should -Be $null -Because "Line '$line' contains no recognized marker and should return `$null"
        }
    }
}

Describe 'ConvertFrom-EngineSummary' -Tag 'Property' {
    # Feature: update-dashboard, Property 4: Summary block parsing extracts all fields
    # **Validates: Requirements 2.4**

    It 'extracts all fields from randomly generated summary blocks (100 iterations)' -Tag 'Property' {
        $seed = 20240601
        $rng = [System.Random]::new($seed)

        $statusPool = @("ok", "FAILED", "SKIPPED", "error", "timeout")

        for ($i = 0; $i -lt 100; $i++) {
            # Generate random statuses
            $wingetStatus = $statusPool[$rng.Next($statusPool.Count)]
            $topgradeStatus = $statusPool[$rng.Next($statusPool.Count)]
            $wuStatus = $statusPool[$rng.Next($statusPool.Count)]
            $eaStatus = $statusPool[$rng.Next($statusPool.Count)]

            # Generate random duration string
            $durationFormats = @(
                # "Xm Ys" format
                { param($r) "$($r.Next(0, 60))m $($r.Next(0, 60))s" },
                # "Xh Ym Zs" format
                { param($r) "$($r.Next(1, 5))h $($r.Next(0, 60))m $($r.Next(0, 60))s" },
                # "HH:mm:ss" format (as the bat actually produces via .ToString('hh\:mm\:ss'))
                { param($r) "{0:D2}:{1:D2}:{2:D2}" -f $r.Next(0, 24), $r.Next(0, 60), $r.Next(0, 60) }
            )
            $durationStr = & $durationFormats[$rng.Next($durationFormats.Count)] $rng

            # Build summary block matching the engine's actual output format
            $summaryBlock = @(
                "========================================"
                "  Summary  (duration: $durationStr)"
                "----------------------------------------"
                "  winget          : $wingetStatus"
                "  topgrade        : $topgradeStatus"
                "  Windows Update  : $wuStatus"
                "  EA app          : $eaStatus"
                "----------------------------------------"
                "  Log: C:\Users\test\Documents\SystemUpdateLogs\Topgrade_20240601_120000.log"
                "========================================"
            ) -join "`r`n"

            # Parse the block
            $result = ConvertFrom-EngineSummary -SummaryText $summaryBlock

            # Assert all fields match
            $result.Winget | Should -BeExactly $wingetStatus -Because "iteration $i winget status"
            $result.Topgrade | Should -BeExactly $topgradeStatus -Because "iteration $i topgrade status"
            $result.WindowsUpdate | Should -BeExactly $wuStatus -Because "iteration $i Windows Update status"
            $result.EAApp | Should -BeExactly $eaStatus -Because "iteration $i EA App status"
            $result.Duration | Should -BeExactly $durationStr -Because "iteration $i duration"
        }
    }
}

Describe 'Get-PendingRebootStatus' -Tag 'Property' {
    # Feature: update-dashboard, Property 5: Reboot indicator detection maps correctly to warning content
    # **Validates: Requirements 3.3, 3.5**

    It 'correctly maps all 8 combinations of 3 reboot indicators' {
        # Enumerate all 2^3 = 8 combinations of (CBS, WindowsUpdate, PendingFileRename)
        foreach ($mask in 0..7) {
            $expectCBS = [bool]($mask -band 1)
            $expectWU  = [bool]($mask -band 2)
            $expectPFR = [bool]($mask -band 4)

            # We need to re-mock inside InModuleScope-like isolation per iteration.
            # Pester 5.x mocks are scoped to the Describe/Context/It block.
            # Use a helper scriptblock invoked in a fresh scope to isolate mocks per combination.

            # Mock Test-Path: return correct boolean based on which registry path is being tested
            Mock Test-Path {
                param($Path)
                if ($Path -like '*Component Based Servicing\RebootPending') {
                    return $expectCBS
                }
                elseif ($Path -like '*WindowsUpdate\Auto Update\RebootRequired') {
                    return $expectWU
                }
                # Default for any other path
                return $false
            }

            # Mock Get-ItemProperty: return PendingFileRenameOperations if PFR is expected
            Mock Get-ItemProperty {
                if ($expectPFR) {
                    return [PSCustomObject]@{ PendingFileRenameOperations = @('\\?\C:\old', '\\?\C:\new') }
                }
                else {
                    return [PSCustomObject]@{ PendingFileRenameOperations = $null }
                }
            }

            $result = Get-PendingRebootStatus

            # Assert IsRebootPending = $true iff ANY of the three is $true
            $expectedRebootPending = ($expectCBS -or $expectWU -or $expectPFR)
            $result.IsRebootPending | Should -Be $expectedRebootPending -Because "mask=$mask (CBS=$expectCBS, WU=$expectWU, PFR=$expectPFR) => IsRebootPending should be $expectedRebootPending"

            # Assert each individual flag matches
            $result.CBS | Should -Be $expectCBS -Because "mask=$mask CBS should be $expectCBS"
            $result.WindowsUpdate | Should -Be $expectWU -Because "mask=$mask WindowsUpdate should be $expectWU"
            $result.PendingFileRename | Should -Be $expectPFR -Because "mask=$mask PendingFileRename should be $expectPFR"
        }
    }

    It 'treats access-denied (exception thrown by Test-Path) as not-set for CBS' {
        Mock Test-Path {
            param($Path)
            if ($Path -like '*Component Based Servicing\RebootPending') {
                throw [System.UnauthorizedAccessException]::new("Access denied")
            }
            elseif ($Path -like '*WindowsUpdate\Auto Update\RebootRequired') {
                return $false
            }
            return $false
        }

        Mock Get-ItemProperty {
            return [PSCustomObject]@{ PendingFileRenameOperations = $null }
        }

        $result = Get-PendingRebootStatus

        $result.CBS | Should -Be $false -Because "access-denied on CBS should be treated as not-set"
        $result.IsRebootPending | Should -Be $false -Because "no indicators are accessible/set"
    }

    It 'treats access-denied (exception thrown by Test-Path) as not-set for WindowsUpdate' {
        Mock Test-Path {
            param($Path)
            if ($Path -like '*Component Based Servicing\RebootPending') {
                return $true
            }
            elseif ($Path -like '*WindowsUpdate\Auto Update\RebootRequired') {
                throw [System.UnauthorizedAccessException]::new("Access denied")
            }
            return $false
        }

        Mock Get-ItemProperty {
            return [PSCustomObject]@{ PendingFileRenameOperations = $null }
        }

        $result = Get-PendingRebootStatus

        $result.WindowsUpdate | Should -Be $false -Because "access-denied on WindowsUpdate should be treated as not-set"
        $result.CBS | Should -Be $true -Because "CBS is accessible and set"
        $result.IsRebootPending | Should -Be $true -Because "CBS is set"
    }

    It 'treats access-denied (exception thrown by Get-ItemProperty) as not-set for PendingFileRename' {
        Mock Test-Path {
            param($Path)
            if ($Path -like '*Component Based Servicing\RebootPending') {
                return $false
            }
            elseif ($Path -like '*WindowsUpdate\Auto Update\RebootRequired') {
                return $true
            }
            return $false
        }

        Mock Get-ItemProperty {
            throw [System.UnauthorizedAccessException]::new("Access denied to Session Manager")
        }

        $result = Get-PendingRebootStatus

        $result.PendingFileRename | Should -Be $false -Because "access-denied on PendingFileRename should be treated as not-set"
        $result.WindowsUpdate | Should -Be $true -Because "WindowsUpdate is accessible and set"
        $result.IsRebootPending | Should -Be $true -Because "WindowsUpdate is set"
    }

    It 'treats all indicators as not-set when all registry accesses throw' {
        Mock Test-Path {
            throw [System.UnauthorizedAccessException]::new("Access denied")
        }

        Mock Get-ItemProperty {
            throw [System.UnauthorizedAccessException]::new("Access denied")
        }

        $result = Get-PendingRebootStatus

        $result.CBS | Should -Be $false -Because "access-denied should be treated as not-set"
        $result.WindowsUpdate | Should -Be $false -Because "access-denied should be treated as not-set"
        $result.PendingFileRename | Should -Be $false -Because "access-denied should be treated as not-set"
        $result.IsRebootPending | Should -Be $false -Because "no indicators accessible means no reboot pending"
    }
}

Describe 'Get-TailLines' -Tag 'Property' {
    # Feature: update-dashboard, Property 6: Last-N-lines trimming preserves only trailing lines
    # **Validates: Requirements 4.7**

    It 'returns correct tail slice for 100+ random arrays with N=50' {
        $rng = [System.Random]::new(20240601)  # Seeded RNG for reproducibility
        $limit = 50

        for ($iter = 0; $iter -lt 120; $iter++) {
            # Generate random array of 0-200 lines
            $lineCount = $rng.Next(0, 201)
            $lines = @()
            if ($lineCount -gt 0) {
                $lines = 0..($lineCount - 1) | ForEach-Object { "Line_${iter}_$_" }
            }

            $result = Get-TailLines -Lines $lines -Limit $limit

            # Assert: output count = min(L, N)
            $expectedCount = [Math]::Min($lineCount, $limit)
            @($result).Count | Should -Be $expectedCount -Because "iter=$iter lineCount=$lineCount limit=$limit => expected $expectedCount lines"

            # Assert: output lines are the last min(L, N) lines in original order
            if ($expectedCount -gt 0) {
                $startIndex = $lineCount - $expectedCount
                for ($j = 0; $j -lt $expectedCount; $j++) {
                    $result[$j] | Should -BeExactly $lines[$startIndex + $j] -Because "iter=$iter result[$j] should match lines[$($startIndex + $j)]"
                }
            }
        }
    }

    It 'returns empty result for empty array' {
        $result = Get-TailLines -Lines @() -Limit 50
        @($result).Count | Should -Be 0
    }

    It 'returns empty result when Limit is 0' {
        $lines = @("a", "b", "c", "d", "e")
        $result = Get-TailLines -Lines $lines -Limit 0
        @($result).Count | Should -Be 0
    }

    It 'returns all lines when count exactly equals limit' {
        $limit = 50
        $lines = 1..$limit | ForEach-Object { "ExactLine_$_" }
        $result = Get-TailLines -Lines $lines -Limit $limit

        @($result).Count | Should -Be $limit
        for ($i = 0; $i -lt $limit; $i++) {
            $result[$i] | Should -BeExactly $lines[$i]
        }
    }

    It 'returns all lines when count is less than limit' {
        $limit = 50
        $lineCount = 20
        $lines = 1..$lineCount | ForEach-Object { "ShortLine_$_" }
        $result = Get-TailLines -Lines $lines -Limit $limit

        @($result).Count | Should -Be $lineCount
        for ($i = 0; $i -lt $lineCount; $i++) {
            $result[$i] | Should -BeExactly $lines[$i]
        }
    }

    It 'returns all lines when limit is greater than array length' {
        $lines = @("alpha", "beta", "gamma")
        $result = Get-TailLines -Lines $lines -Limit 200

        @($result).Count | Should -Be 3
        $result[0] | Should -BeExactly "alpha"
        $result[1] | Should -BeExactly "beta"
        $result[2] | Should -BeExactly "gamma"
    }
}

Describe 'Pin list serialization round-trip' -Tag 'Property' {
    # Feature: update-dashboard, Property 7: Pin list serialization round-trip
    # **Validates: Requirements 5.1, 5.2**

    BeforeAll {
        $script:Seed = 20240701
        $script:Rng = [System.Random]::new($script:Seed)

        function New-TempBatWithPinSection {
            <#
            .SYNOPSIS
                Creates a temp .bat file with an echo [pins] marker and a subsequent section.
            #>
            $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.bat'
            $content = @(
                '@echo off'
                'rem -- Header section'
                'echo Starting update...'
                ''
                'echo [pins] Pinning packages in winget and chocolatey...'
                ''
                'rem -- Winget upgrades'
                'echo [winget] Running winget upgrades...'
                'winget upgrade --all'
            )
            Set-Content -LiteralPath $tempFile -Value $content -Encoding ASCII
            return $tempFile
        }

        function Get-RandomAlphaSegment {
            param([System.Random]$Rng, [int]$MinLen = 2, [int]$MaxLen = 10)
            $len = $Rng.Next($MinLen, $MaxLen + 1)
            $chars = [char[]]::new($len)
            $pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
            for ($i = 0; $i -lt $len; $i++) {
                $chars[$i] = $pool[$Rng.Next($pool.Length)]
            }
            return -join $chars
        }

        function Get-RandomWingetId {
            param([System.Random]$Rng)
            # Dot-separated segments like "Company.Product" or "Company.Product.Sub"
            $segmentCount = $Rng.Next(2, 5) # 2 to 4 segments
            $segments = @()
            for ($s = 0; $s -lt $segmentCount; $s++) {
                $segments += Get-RandomAlphaSegment -Rng $Rng -MinLen 2 -MaxLen 10
            }
            return $segments -join '.'
        }

        function Get-RandomChocoId {
            param([System.Random]$Rng)
            # Alphanumeric-hyphen like "package-name"
            $partCount = $Rng.Next(1, 4) # 1 to 3 parts
            $parts = @()
            for ($p = 0; $p -lt $partCount; $p++) {
                $parts += Get-RandomAlphaSegment -Rng $Rng -MinLen 2 -MaxLen 8
            }
            return ($parts -join '-').ToLower()
        }

        function New-RandomPinList {
            param([System.Random]$Rng, [int]$Count, [string]$ManagerForce = $null)
            $pins = @()
            for ($i = 0; $i -lt $Count; $i++) {
                if ($ManagerForce) {
                    $manager = $ManagerForce
                } else {
                    $manager = if ($Rng.Next(2) -eq 0) { 'winget' } else { 'choco' }
                }

                if ($manager -eq 'winget') {
                    $id = Get-RandomWingetId -Rng $Rng
                } else {
                    $id = Get-RandomChocoId -Rng $Rng
                }

                $pins += [PSCustomObject]@{
                    Id      = $id
                    Manager = $manager
                }
            }
            return $pins
        }
    }

    It 'round-trips 100+ random valid pin lists (seeded RNG)' {
        $rng = [System.Random]::new($script:Seed)

        for ($iter = 0; $iter -lt 110; $iter++) {
            $pinCount = $rng.Next(0, 16) # 0 to 15 pins
            $pins = @(New-RandomPinList -Rng $rng -Count $pinCount)

            # Create temp bat with pin section
            $tempBat = New-TempBatWithPinSection

            try {
                # Write pins to the bat file
                Set-PinListInBat -BatFilePath $tempBat -Pins $pins

                # Re-read pins from the bat file
                $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)

                # Assert same count
                $readBack.Count | Should -BeExactly $pins.Count -Because "iteration ${iter} pin count should match (wrote $($pins.Count) pins)"

                # Assert same IDs in same order, same managers
                # Note: Set-PinListInBat groups by manager (winget first, then choco)
                # So the expected order is all winget pins first, then all choco pins
                $expectedOrder = @()
                $expectedOrder += @($pins | Where-Object { $_.Manager -eq 'winget' })
                $expectedOrder += @($pins | Where-Object { $_.Manager -eq 'choco' })

                for ($j = 0; $j -lt $expectedOrder.Count; $j++) {
                    $readBack[$j].Id | Should -BeExactly $expectedOrder[$j].Id -Because "iteration ${iter} pin ${j} ID should match"
                    $readBack[$j].Manager | Should -BeExactly $expectedOrder[$j].Manager -Because "iteration ${iter} pin ${j} Manager should match"
                }
            }
            finally {
                Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'round-trips an empty pin list' {
        $tempBat = New-TempBatWithPinSection
        try {
            Set-PinListInBat -BatFilePath $tempBat -Pins @()
            $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)
            $readBack.Count | Should -BeExactly 0 -Because "empty pin list should produce zero parsed pins"
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips a single winget pin' {
        $rng = [System.Random]::new(999)
        $pins = New-RandomPinList -Rng $rng -Count 1 -ManagerForce 'winget'
        $tempBat = New-TempBatWithPinSection
        try {
            Set-PinListInBat -BatFilePath $tempBat -Pins $pins
            $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)
            $readBack.Count | Should -BeExactly 1
            $readBack[0].Id | Should -BeExactly $pins[0].Id
            $readBack[0].Manager | Should -BeExactly 'winget'
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips a single choco pin' {
        $rng = [System.Random]::new(888)
        $pins = New-RandomPinList -Rng $rng -Count 1 -ManagerForce 'choco'
        $tempBat = New-TempBatWithPinSection
        try {
            Set-PinListInBat -BatFilePath $tempBat -Pins $pins
            $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)
            $readBack.Count | Should -BeExactly 1
            $readBack[0].Id | Should -BeExactly $pins[0].Id
            $readBack[0].Manager | Should -BeExactly 'choco'
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips all-winget pin lists (5 to 15 pins)' {
        $rng = [System.Random]::new(777)
        $count = $rng.Next(5, 16)
        $pins = New-RandomPinList -Rng $rng -Count $count -ManagerForce 'winget'
        $tempBat = New-TempBatWithPinSection
        try {
            Set-PinListInBat -BatFilePath $tempBat -Pins $pins
            $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)
            $readBack.Count | Should -BeExactly $count
            for ($j = 0; $j -lt $count; $j++) {
                $readBack[$j].Id | Should -BeExactly $pins[$j].Id
                $readBack[$j].Manager | Should -BeExactly 'winget'
            }
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips all-choco pin lists (5 to 15 pins)' {
        $rng = [System.Random]::new(666)
        $count = $rng.Next(5, 16)
        $pins = New-RandomPinList -Rng $rng -Count $count -ManagerForce 'choco'
        $tempBat = New-TempBatWithPinSection
        try {
            Set-PinListInBat -BatFilePath $tempBat -Pins $pins
            $readBack = @(Get-PinListFromBat -BatFilePath $tempBat)
            $readBack.Count | Should -BeExactly $count
            for ($j = 0; $j -lt $count; $j++) {
                $readBack[$j].Id | Should -BeExactly $pins[$j].Id
                $readBack[$j].Manager | Should -BeExactly 'choco'
            }
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves content outside the pin section' {
        $tempBat = New-TempBatWithPinSection
        try {
            # Read original content
            $originalLines = Get-Content -LiteralPath $tempBat

            # Write some pins
            $rng = [System.Random]::new(555)
            $pins = @(New-RandomPinList -Rng $rng -Count 5)
            Set-PinListInBat -BatFilePath $tempBat -Pins $pins

            # Read back full file
            $newLines = Get-Content -LiteralPath $tempBat

            # The header section (before echo [pins]) should be preserved
            $newLines[0] | Should -BeExactly '@echo off'
            $newLines[1] | Should -BeExactly 'rem -- Header section'
            $newLines[2] | Should -BeExactly 'echo Starting update...'

            # The section after pins should be preserved (rem -- Winget upgrades)
            $afterPinContent = $newLines | Where-Object { $_ -match 'rem -- Winget upgrades' }
            $afterPinContent | Should -Not -BeNullOrEmpty -Because "content after pin section should be preserved"

            # winget upgrade line should also be preserved
            $wingetLine = $newLines | Where-Object { $_ -match 'winget upgrade --all' }
            $wingetLine | Should -Not -BeNullOrEmpty -Because "lines after pin section should be preserved"
        }
        finally {
            Remove-Item -LiteralPath $tempBat -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-PinId' -Tag 'Property' {
    # Feature: update-dashboard, Property 8: Pin ID validation accepts only well-formed IDs and rejects duplicates
    # **Validates: Requirements 5.3, 5.4**

    BeforeAll {
        $script:Seed = 20240601
        $script:Rng = [System.Random]::new($script:Seed)

        function Get-RandomAlphanumSegment {
            param([System.Random]$Rng, [int]$MinLen = 1, [int]$MaxLen = 12)
            $len = $Rng.Next($MinLen, $MaxLen + 1)
            $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
            $result = ''
            for ($i = 0; $i -lt $len; $i++) {
                $result += $chars[$Rng.Next($chars.Length)]
            }
            return $result
        }

        function Get-RandomAlphanumHyphenSegment {
            param([System.Random]$Rng, [int]$MinLen = 1, [int]$MaxLen = 12)
            $len = $Rng.Next($MinLen, $MaxLen + 1)
            $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_'
            $result = ''
            for ($i = 0; $i -lt $len; $i++) {
                $result += $chars[$Rng.Next($chars.Length)]
            }
            return $result
        }

        function New-RandomWingetId {
            param([System.Random]$Rng)
            # winget IDs: ^\w[\w\-]+(\.[\w\-]+)+$ — at least 2 dot-separated segments
            $segCount = $Rng.Next(2, 5)
            $segments = @()
            for ($s = 0; $s -lt $segCount; $s++) {
                $segments += Get-RandomAlphanumHyphenSegment -Rng $Rng -MinLen 2 -MaxLen 10
            }
            # Ensure first char is a word char (not hyphen) — our helper already generates alphanum+hyphen+underscore
            # Force first char to be alphanum
            $id = ($segments -join '.')
            $firstChar = ('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_')[$Rng.Next(63)]
            $id = $firstChar + $id.Substring(1)
            return $id
        }

        function New-RandomChocoId {
            param([System.Random]$Rng)
            # choco IDs: ^[\w\-]+$ — alphanum, underscore, hyphen only, no dots
            return Get-RandomAlphanumHyphenSegment -Rng $Rng -MinLen 3 -MaxLen 20
        }
    }

    It 'accepts known valid winget IDs' {
        $validWingetIds = @(
            'Microsoft.VisualStudioCode',
            'Adobe.Acrobat.Reader.64-bit',
            '7zip.7zip'
        )

        foreach ($id in $validWingetIds) {
            $result = Test-PinId -Id $id -Manager 'winget' -ExistingPins @()
            $result.Valid | Should -BeTrue -Because "winget ID '$id' should be valid"
            $result.Reason | Should -BeNullOrEmpty
        }
    }

    It 'accepts known valid choco IDs' {
        $validChocoIds = @(
            'adobereader',
            '7zip',
            'git-for-windows'
        )

        foreach ($id in $validChocoIds) {
            $result = Test-PinId -Id $id -Manager 'choco' -ExistingPins @()
            $result.Valid | Should -BeTrue -Because "choco ID '$id' should be valid"
            $result.Reason | Should -BeNullOrEmpty
        }
    }

    It 'rejects known invalid IDs' {
        # Empty string
        $result = Test-PinId -Id '' -Manager 'winget' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "empty string should be rejected"

        $result = Test-PinId -Id '' -Manager 'choco' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "empty string should be rejected for choco"

        # Contains whitespace
        $result = Test-PinId -Id 'has space' -Manager 'winget' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "whitespace should be rejected"

        $result = Test-PinId -Id "tab`there" -Manager 'choco' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "tab whitespace should be rejected"

        # winget without dot (no dot-separated segments)
        $result = Test-PinId -Id 'justanid' -Manager 'winget' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "winget ID without dot-separated segments should be rejected"

        # choco with dot (dots not in [\w\-])
        $result = Test-PinId -Id 'package.name' -Manager 'choco' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "choco ID with dot should be rejected"

        # Special characters
        $result = Test-PinId -Id 'pkg@name' -Manager 'winget' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "special char @ should be rejected"

        $result = Test-PinId -Id 'pkg/name' -Manager 'choco' -ExistingPins @()
        $result.Valid | Should -BeFalse -Because "special char / should be rejected"
    }

    It 'correctly validates 100+ randomly generated IDs (valid and invalid)' {
        $iterations = 120

        for ($i = 0; $i -lt $iterations; $i++) {
            $choice = $script:Rng.Next(0, 4)

            switch ($choice) {
                0 {
                    # Generate a valid winget ID
                    $id = New-RandomWingetId -Rng $script:Rng
                    $result = Test-PinId -Id $id -Manager 'winget' -ExistingPins @()
                    $result.Valid | Should -BeTrue -Because "iteration ${i}: generated valid winget ID '$id' should be accepted"
                }
                1 {
                    # Generate a valid choco ID
                    $id = New-RandomChocoId -Rng $script:Rng
                    $result = Test-PinId -Id $id -Manager 'choco' -ExistingPins @()
                    $result.Valid | Should -BeTrue -Because "iteration ${i}: generated valid choco ID '$id' should be accepted"
                }
                2 {
                    # Generate invalid ID with injected whitespace
                    $base = Get-RandomAlphanumSegment -Rng $script:Rng -MinLen 3 -MaxLen 10
                    $pos = $script:Rng.Next(1, $base.Length)
                    $id = $base.Substring(0, $pos) + ' ' + $base.Substring($pos)
                    $manager = @('winget', 'choco')[$script:Rng.Next(2)]
                    $result = Test-PinId -Id $id -Manager $manager -ExistingPins @()
                    $result.Valid | Should -BeFalse -Because "iteration ${i}: ID '$id' with whitespace should be rejected"
                }
                3 {
                    # Generate invalid ID with special characters
                    $specialChars = '@', '/', '!', '#', '$', '%', '^', '&', '*', '(', ')', '+', '='
                    $base = Get-RandomAlphanumSegment -Rng $script:Rng -MinLen 3 -MaxLen 10
                    $specialChar = $specialChars[$script:Rng.Next($specialChars.Count)]
                    $pos = $script:Rng.Next(0, $base.Length + 1)
                    $id = $base.Insert($pos, $specialChar)
                    $manager = @('winget', 'choco')[$script:Rng.Next(2)]
                    $result = Test-PinId -Id $id -Manager $manager -ExistingPins @()
                    $result.Valid | Should -BeFalse -Because "iteration ${i}: ID '$id' with special char '$specialChar' should be rejected"
                }
            }
        }
    }

    It 'rejects duplicate IDs for the same manager' {
        $existingPins = @(
            [PSCustomObject]@{ Id = 'Microsoft.VisualStudioCode'; Manager = 'winget' },
            [PSCustomObject]@{ Id = 'adobereader'; Manager = 'choco' }
        )

        # Same ID + same manager → rejected
        $result = Test-PinId -Id 'Microsoft.VisualStudioCode' -Manager 'winget' -ExistingPins $existingPins
        $result.Valid | Should -BeFalse -Because "duplicate winget ID should be rejected"
        $result.Reason | Should -BeLike '*already exists*'

        $result = Test-PinId -Id 'adobereader' -Manager 'choco' -ExistingPins $existingPins
        $result.Valid | Should -BeFalse -Because "duplicate choco ID should be rejected"
        $result.Reason | Should -BeLike '*already exists*'
    }

    It 'accepts same ID for a different manager (no cross-manager duplicate rejection)' {
        $existingPins = @(
            [PSCustomObject]@{ Id = 'Microsoft.VisualStudioCode'; Manager = 'winget' }
        )

        # Same ID but different manager → accepted (choco format won't match winget format though)
        # Use an ID that's valid for choco: e.g., 'some-package'
        $existingPinsChoco = @(
            [PSCustomObject]@{ Id = 'some-package'; Manager = 'choco' }
        )

        # 'some-package' is valid for winget? No — it needs dots. Use a winget-valid ID for winget manager
        # Test: existing pin is winget, try adding same ID as choco (if format allows)
        # 'git-for-windows' is valid choco, not valid winget (no dots). So cross-check:
        $existingPinsWinget = @(
            [PSCustomObject]@{ Id = 'git-for-windows'; Manager = 'winget' }
        )

        # Adding 'git-for-windows' as choco — different manager, should not trigger duplicate
        $result = Test-PinId -Id 'git-for-windows' -Manager 'choco' -ExistingPins $existingPinsWinget
        $result.Valid | Should -BeTrue -Because "same ID with different manager should be accepted"
    }

    It 'rejects duplicates across 100+ random iterations with injected duplicates' {
        for ($i = 0; $i -lt 100; $i++) {
            $manager = @('winget', 'choco')[$script:Rng.Next(2)]

            if ($manager -eq 'winget') {
                $id = New-RandomWingetId -Rng $script:Rng
            } else {
                $id = New-RandomChocoId -Rng $script:Rng
            }

            # Create existing pins with this ID present
            $existingPins = @(
                [PSCustomObject]@{ Id = $id; Manager = $manager }
            )

            # Try to add the same ID+Manager → should be rejected
            $result = Test-PinId -Id $id -Manager $manager -ExistingPins $existingPins
            $result.Valid | Should -BeFalse -Because "iteration ${i}: duplicate ID '$id' for manager '$manager' should be rejected"
            $result.Reason | Should -BeLike '*already exists*'

            # Try the same ID with the OTHER manager → should be accepted (format permitting)
            $otherManager = if ($manager -eq 'winget') { 'choco' } else { 'winget' }
            $resultOther = Test-PinId -Id $id -Manager $otherManager -ExistingPins $existingPins

            # The other manager may reject on format grounds (e.g., winget ID with dots fails choco format)
            # but should NOT reject on duplicate grounds
            if (-not $resultOther.Valid) {
                $resultOther.Reason | Should -Not -BeLike '*already exists*' -Because "iteration ${i}: ID '$id' for different manager '$otherManager' should not be rejected as duplicate"
            }
        }
    }
}

Describe 'New-ToastContent' -Tag 'Property' {
    # Feature: update-dashboard, Property 9: Toast notification content reflects category statuses
    # Validates: Requirements 6.1, 6.2

    BeforeAll {
        $script:Seed = 20240901
        $script:Rng = [System.Random]::new($script:Seed)
        $script:CategoryPool = @('WindowsUpdate', 'Store', 'Apps', 'Drivers')
        $script:StatusPool = @('ok', 'error')
    }

    It 'toast title contains "Success" when all statuses are ok, "Issues" when any is error (100+ iterations)' {
        $rng = [System.Random]::new($script:Seed)

        for ($iter = 0; $iter -lt 120; $iter++) {
            # Random number of categories (1-4)
            $catCount = $rng.Next(1, 5)

            # Shuffle and pick $catCount categories from pool
            $shuffled = $script:CategoryPool | Sort-Object { $rng.Next() }
            $selectedCategories = $shuffled[0..($catCount - 1)]

            # Assign random statuses
            $statusMap = @{}
            foreach ($cat in $selectedCategories) {
                $statusMap[$cat] = $script:StatusPool[$rng.Next($script:StatusPool.Count)]
            }

            $result = New-ToastContent -CategoryStatuses $statusMap

            # Check title correctness
            $allOk = ($statusMap.Values | Where-Object { $_ -ne 'ok' }).Count -eq 0

            if ($allOk) {
                $result.Title | Should -Match '(?i)success' -Because "iteration $iter all statuses are 'ok' so title should contain 'Success'. Map: $($statusMap | ConvertTo-Json -Compress)"
            } else {
                $result.Title | Should -Match '(?i)issues' -Because "iteration $iter has at least one 'error' so title should contain 'Issues'. Map: $($statusMap | ConvertTo-Json -Compress)"
            }

            # Check body completeness: every category name should appear
            foreach ($cat in $selectedCategories) {
                $result.Body | Should -Match ([regex]::Escape($cat)) -Because "iteration $iter body should contain category '$cat'"
            }

            # Check body completeness: every status value paired with its category
            foreach ($cat in $selectedCategories) {
                $expectedStatus = $statusMap[$cat]
                $result.Body | Should -Match ([regex]::Escape("${cat}: ${expectedStatus}")) -Because "iteration $iter body should contain '${cat}: ${expectedStatus}'"
            }
        }
    }

    It 'single category "ok" produces title with Success' {
        $statusMap = @{ 'WindowsUpdate' = 'ok' }
        $result = New-ToastContent -CategoryStatuses $statusMap

        $result.Title | Should -Match '(?i)success'
        $result.Body | Should -Match 'WindowsUpdate'
        $result.Body | Should -Match 'ok'
    }

    It 'single category "error" produces title with Issues' {
        $statusMap = @{ 'Store' = 'error' }
        $result = New-ToastContent -CategoryStatuses $statusMap

        $result.Title | Should -Match '(?i)issues'
        $result.Body | Should -Match 'Store'
        $result.Body | Should -Match 'error'
    }

    It 'all 4 categories with "ok" produces title with Success' {
        $statusMap = @{
            'WindowsUpdate' = 'ok'
            'Store'         = 'ok'
            'Apps'          = 'ok'
            'Drivers'       = 'ok'
        }
        $result = New-ToastContent -CategoryStatuses $statusMap

        $result.Title | Should -Match '(?i)success'
        foreach ($cat in $statusMap.Keys) {
            $result.Body | Should -Match ([regex]::Escape($cat))
            $result.Body | Should -Match ([regex]::Escape("${cat}: ok"))
        }
    }

    It 'mixed statuses (some ok, some error) produces title with Issues and lists all categories' {
        $statusMap = @{
            'WindowsUpdate' = 'ok'
            'Store'         = 'error'
            'Apps'          = 'ok'
            'Drivers'       = 'error'
        }
        $result = New-ToastContent -CategoryStatuses $statusMap

        $result.Title | Should -Match '(?i)issues'
        $result.Body | Should -Match 'WindowsUpdate: ok'
        $result.Body | Should -Match 'Store: error'
        $result.Body | Should -Match 'Apps: ok'
        $result.Body | Should -Match 'Drivers: error'
    }

    It 'body contains category-status pairs for all permutations of 2 categories (seeded)' {
        $rng = [System.Random]::new(12345)

        # Test all pairs of 2 categories from the pool
        for ($i = 0; $i -lt $script:CategoryPool.Count; $i++) {
            for ($j = $i + 1; $j -lt $script:CategoryPool.Count; $j++) {
                $cat1 = $script:CategoryPool[$i]
                $cat2 = $script:CategoryPool[$j]

                # Test both with ok, both with error, and mixed
                $combos = @(
                    @{ $cat1 = 'ok'; $cat2 = 'ok' },
                    @{ $cat1 = 'error'; $cat2 = 'error' },
                    @{ $cat1 = 'ok'; $cat2 = 'error' },
                    @{ $cat1 = 'error'; $cat2 = 'ok' }
                )

                foreach ($statusMap in $combos) {
                    $result = New-ToastContent -CategoryStatuses $statusMap

                    $allOk = ($statusMap.Values | Where-Object { $_ -ne 'ok' }).Count -eq 0

                    if ($allOk) {
                        $result.Title | Should -Match '(?i)success'
                    } else {
                        $result.Title | Should -Match '(?i)issues'
                    }

                    foreach ($key in $statusMap.Keys) {
                        $val = $statusMap[$key]
                        $result.Body | Should -Match ([regex]::Escape("${key}: ${val}"))
                    }
                }
            }
        }
    }
}

Describe 'ConvertFrom-PnpUtilOutput' -Tag 'Property' {
    # Feature: update-dashboard, Property 10: Driver store output parsing and sorting
    # **Validates: Requirements 8.1, 8.2**

    BeforeAll {
        $script:Seed = 20240801
        $script:Rng = [System.Random]::new($script:Seed)

        $script:ClassNamePool = @(
            'Display', 'Net', 'USB', 'HIDClass', 'Media', 'System',
            'Bluetooth', 'Printer', 'SCSIAdapter', 'Camera', 'Firmware',
            'AudioEndpoint', 'Monitor', 'DiskDrive', 'CDROM'
        )

        function Get-RandomPublishedName {
            param([System.Random]$Rng)
            $num = $Rng.Next(0, 200)
            return "oem${num}.inf"
        }

        function Get-RandomClassName {
            param([System.Random]$Rng)
            return $script:ClassNamePool[$Rng.Next($script:ClassNamePool.Count)]
        }

        function Get-RandomVersionString {
            param([System.Random]$Rng)
            $major = $Rng.Next(1, 100)
            $minor = $Rng.Next(0, 100)
            $build = $Rng.Next(0, 10000)
            $rev = $Rng.Next(0, 10000)
            return "${major}.${minor}.${build}.${rev}"
        }

        function Get-RandomDriverDate {
            param([System.Random]$Rng)
            $month = $Rng.Next(1, 13)
            $day = $Rng.Next(1, 29) # Keep it simple, max 28 for all months
            $year = $Rng.Next(2018, 2026)
            return "{0:D2}/{1:D2}/{2}" -f $month, $day, $year
        }

        function Get-RandomGuid {
            param([System.Random]$Rng)
            $bytes = [byte[]]::new(16)
            $Rng.NextBytes($bytes)
            return [guid]::new($bytes).ToString('B')
        }

        function New-PnpUtilDriverBlock {
            param(
                [string]$PublishedName,
                [string]$ClassName,
                [string]$Version,
                [string]$Date,
                [System.Random]$Rng
            )
            # Generate additional random fields for realism
            $originalName = "driver_$($Rng.Next(1000, 9999)).inf"
            $provider = @('Intel', 'NVIDIA', 'Realtek', 'Microsoft', 'AMD', 'Broadcom', 'Qualcomm')[$Rng.Next(7)]
            $guid = Get-RandomGuid -Rng $Rng
            $signer = "Microsoft Windows Hardware Compatibility Publisher"

            $block = @(
                "Published Name:     $PublishedName"
                "Original Name:      $originalName"
                "Provider Name:      $provider"
                "Class Name:         $ClassName"
                "Class GUID:         $guid"
                "Driver Version:     $Date $Version"
                "Signer Name:        $signer"
            )
            return ($block -join "`r`n")
        }

        function New-PnpUtilOutput {
            param(
                [array]$DriverData,
                [System.Random]$Rng
            )
            $header = "Microsoft PnP Utility"
            $separator = ""

            $blocks = @($header, $separator)
            foreach ($driver in $DriverData) {
                $block = New-PnpUtilDriverBlock `
                    -PublishedName $driver.PublishedName `
                    -ClassName $driver.ClassName `
                    -Version $driver.Version `
                    -Date $driver.Date `
                    -Rng $Rng
                $blocks += $block
                $blocks += $separator
            }
            return ($blocks -join "`r`n")
        }
    }

    It 'parses and sorts 100+ randomly generated pnputil outputs correctly' {
        $rng = [System.Random]::new($script:Seed)

        for ($iter = 0; $iter -lt 110; $iter++) {
            # Generate 1-10 driver blocks
            $driverCount = $rng.Next(1, 11)
            $driverData = @()

            for ($d = 0; $d -lt $driverCount; $d++) {
                $driverData += [PSCustomObject]@{
                    PublishedName = Get-RandomPublishedName -Rng $rng
                    ClassName     = Get-RandomClassName -Rng $rng
                    Version       = Get-RandomVersionString -Rng $rng
                    Date          = Get-RandomDriverDate -Rng $rng
                }
            }

            # Build pnputil-style output
            $output = New-PnpUtilOutput -DriverData $driverData -Rng $rng

            # Parse it
            $result = ConvertFrom-PnpUtilOutput -PnpUtilText $output

            # Assert: all entries extracted
            @($result).Count | Should -Be $driverCount -Because "iteration ${iter}: generated $driverCount drivers, expected $driverCount parsed entries"

            # Assert: sort order — alphabetically by ClassName (case-insensitive), then by PublishedName
            $expectedOrder = $driverData | Sort-Object @{Expression={$_.ClassName}; Ascending=$true}, @{Expression={$_.PublishedName}; Ascending=$true}

            for ($j = 0; $j -lt @($result).Count; $j++) {
                $result[$j].PublishedName | Should -BeExactly $expectedOrder[$j].PublishedName -Because "iteration ${iter} index ${j}: PublishedName should match sorted order"
                $result[$j].ClassName | Should -BeExactly $expectedOrder[$j].ClassName -Because "iteration ${iter} index ${j}: ClassName should match sorted order"
                $result[$j].DriverVersion | Should -BeExactly $expectedOrder[$j].Version -Because "iteration ${iter} index ${j}: DriverVersion should match"
                $result[$j].DriverDate | Should -BeExactly $expectedOrder[$j].Date -Because "iteration ${iter} index ${j}: DriverDate should match"
            }
        }
    }

    It 'returns empty array for empty string input' {
        $result = ConvertFrom-PnpUtilOutput -PnpUtilText ''
        @($result).Count | Should -Be 0
    }

    It 'returns empty array for whitespace-only input' {
        $result = ConvertFrom-PnpUtilOutput -PnpUtilText '   '
        @($result).Count | Should -Be 0
    }

    It 'returns empty array for header-only output (no driver blocks)' {
        $headerOnly = "Microsoft PnP Utility`r`n`r`nEnumerating all 3rd-party drivers:`r`n"
        $result = ConvertFrom-PnpUtilOutput -PnpUtilText $headerOnly
        @($result).Count | Should -Be 0
    }

    It 'correctly parses a single driver block' {
        $rng = [System.Random]::new(12345)
        $singleDriver = @([PSCustomObject]@{
            PublishedName = 'oem42.inf'
            ClassName     = 'Display'
            Version       = '31.0.15.5263'
            Date          = '03/15/2024'
        })

        $output = New-PnpUtilOutput -DriverData $singleDriver -Rng $rng
        $result = ConvertFrom-PnpUtilOutput -PnpUtilText $output

        @($result).Count | Should -Be 1
        $result[0].PublishedName | Should -BeExactly 'oem42.inf'
        $result[0].ClassName | Should -BeExactly 'Display'
        $result[0].DriverVersion | Should -BeExactly '31.0.15.5263'
        $result[0].DriverDate | Should -BeExactly '03/15/2024'
    }

    It 'sorts results by ClassName then PublishedName' {
        $rng = [System.Random]::new(99999)
        # Create drivers with specific class names and published names to verify sort
        $drivers = @(
            [PSCustomObject]@{ PublishedName = 'oem10.inf'; ClassName = 'USB';     Version = '1.0.0.1'; Date = '01/01/2024' }
            [PSCustomObject]@{ PublishedName = 'oem5.inf';  ClassName = 'Display'; Version = '2.0.0.1'; Date = '02/01/2024' }
            [PSCustomObject]@{ PublishedName = 'oem3.inf';  ClassName = 'Display'; Version = '3.0.0.1'; Date = '03/01/2024' }
            [PSCustomObject]@{ PublishedName = 'oem7.inf';  ClassName = 'Net';     Version = '4.0.0.1'; Date = '04/01/2024' }
            [PSCustomObject]@{ PublishedName = 'oem1.inf';  ClassName = 'Net';     Version = '5.0.0.1'; Date = '05/01/2024' }
        )

        $output = New-PnpUtilOutput -DriverData $drivers -Rng $rng
        $result = ConvertFrom-PnpUtilOutput -PnpUtilText $output

        @($result).Count | Should -Be 5

        # Expected order: Display (oem3, oem5), Net (oem1, oem7), USB (oem10)
        $result[0].ClassName | Should -BeExactly 'Display'
        $result[0].PublishedName | Should -BeExactly 'oem3.inf'

        $result[1].ClassName | Should -BeExactly 'Display'
        $result[1].PublishedName | Should -BeExactly 'oem5.inf'

        $result[2].ClassName | Should -BeExactly 'Net'
        $result[2].PublishedName | Should -BeExactly 'oem1.inf'

        $result[3].ClassName | Should -BeExactly 'Net'
        $result[3].PublishedName | Should -BeExactly 'oem7.inf'

        $result[4].ClassName | Should -BeExactly 'USB'
        $result[4].PublishedName | Should -BeExactly 'oem10.inf'
    }
}
