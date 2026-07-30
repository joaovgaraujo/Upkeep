# Functions.ps1
# Pure logic functions extracted for testability.
# Dot-source this file from UpdateDashboard.ps1 and from Pester tests.

function ConvertTo-SkipFlags {
    <#
    .SYNOPSIS
        Converts category checkbox states to engine environment variable skip flags.
    .DESCRIPTION
        Input: hashtable of category name (WindowsUpdate, Store, Apps, Drivers) to bool (checked=$true).
        Output: hashtable with DASHBOARD_SKIP_* env var names set to "1" for unchecked categories,
        plus an InvokeEngine boolean ($true iff at least one of WindowsUpdate, Store, Apps is checked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Categories
    )

    $result = @{}

    # Map unchecked categories to their corresponding skip environment variables
    if (-not $Categories['WindowsUpdate']) {
        $result['DASHBOARD_SKIP_WINUPDATE'] = "1"
    }
    if (-not $Categories['Store']) {
        $result['DASHBOARD_SKIP_STORE'] = "1"
    }
    if (-not $Categories['Apps']) {
        $result['DASHBOARD_SKIP_APPS'] = "1"
    }

    # InvokeEngine is true iff at least one of WindowsUpdate, Store, Apps is checked
    # Drivers does NOT affect InvokeEngine — it's handled separately
    $result['InvokeEngine'] = [bool]($Categories['WindowsUpdate'] -or $Categories['Store'] -or $Categories['Apps'])

    return $result
}

function Add-LogLine {
    <#
    .SYNOPSIS
        Appends a line to the log buffer, enforcing a maximum line cap.
    .DESCRIPTION
        Appends the given line to a List[string] buffer. If the buffer exceeds MaxLines,
        oldest entries are removed so that only the most recent MaxLines remain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Buffer,

        [Parameter(Mandatory)]
        [string]$Line,

        [Parameter()]
        [int]$MaxLines = 10000
    )

    $Buffer.Add($Line)

    if ($Buffer.Count -gt $MaxLines) {
        $excess = $Buffer.Count - $MaxLines
        $Buffer.RemoveRange(0, $excess)
    }
}

function Get-CategoryFromMarker {
    <#
    .SYNOPSIS
        Classifies an output line by its category marker tag.
    .DESCRIPTION
        Input: a single output line string.
        Output: category name string (WindowsUpdate, Store, Apps) or $null if no marker found.
        Recognized markers: [winget], [store], [winupdate], [ea], [launch].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $CategoryMarkers = [ordered]@{
        '[winget]'      = 'Apps'
        '[store]'       = 'Store'
        '[winupdate]'   = 'WindowsUpdate'
        '[ea]'          = 'Apps'
        '[launch]'      = 'Apps'
        '[steam]'       = 'Apps'
        '[jdownloader]' = 'Apps'
    }

    foreach ($marker in $CategoryMarkers.Keys) {
        if ($Line.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $CategoryMarkers[$marker]
        }
    }

    return $null
}

function ConvertFrom-EngineSummary {
    <#
    .SYNOPSIS
        Parses the engine's end-of-run summary block into a structured object.
    .DESCRIPTION
        Input: multi-line summary block string (starts with ========).
        Output: PSCustomObject with Winget, Topgrade, WindowsUpdate, EAApp, Duration properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SummaryText
    )

    # Initialize all fields to $null
    $winget = $null
    $topgrade = $null
    $windowsUpdate = $null
    $eaApp = $null
    $duration = $null
    $store = $null
    $steam = $null
    $jdownloader = $null

    # Split the block into lines
    $lines = $SummaryText -split '\r?\n'

    foreach ($line in $lines) {
        # Skip separator lines (======, ------) and empty lines
        if ($line -match '^\s*[=\-]+\s*$' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Try to extract duration from the "Summary (duration: ...)" header line
        if ($line -match 'duration\s*:\s*(.+?)\s*\)') {
            $duration = $Matches[1].Trim()
            continue
        }

        # Try to match key:value pairs (e.g., "  winget          : ok")
        if ($line -match '^\s*(.+?)\s*:\s*(.+?)\s*$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            # Match keys case-insensitively, tolerant of whitespace variations
            switch -Regex ($key) {
                '(?i)^winget$' { $winget = $value }
                '(?i)^topgrade$' { $topgrade = $value }
                '(?i)^windows\s*update$' { $windowsUpdate = $value }
                '(?i)^ea\s*app$' { $eaApp = $value }
                '(?i)^duration$' { $duration = $value }
                '(?i)^store$' { $store = $value }
                '(?i)^steam(\s*games)?$' { $steam = $value }
                '(?i)^jdownloader$' { $jdownloader = $value }
            }
        }
    }

    [PSCustomObject]@{
        Winget        = $winget
        Topgrade      = $topgrade
        WindowsUpdate = $windowsUpdate
        EAApp         = $eaApp
        Duration      = $duration
        Store         = $store
        Steam         = $steam
        JDownloader   = $jdownloader
    }
}

function Get-TailLines {
    <#
    .SYNOPSIS
        Returns the last N lines from a string array.
    .DESCRIPTION
        Input: string array and limit N.
        Output: last min(L, N) lines in order, where L is the array length.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [int]$Limit
    )

    $count = [Math]::Min($Lines.Count, $Limit)

    if ($count -eq 0 -or $Lines.Count -eq 0) {
        return @()
    }

    return $Lines[($Lines.Count - $count)..($Lines.Count - 1)]
}

function Get-PinListFromBat {
    <#
    .SYNOPSIS
        Parses pinned package entries from the Update_Engine batch file.
    .DESCRIPTION
        Input: path to the .bat file.
        Output: array of PSCustomObjects with Id, Manager, LineNumber properties.
        Parses "winget pin add --id <ID>" and "choco pin add -n=<name>" lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatFilePath
    )

    if (-not (Test-Path -LiteralPath $BatFilePath)) {
        throw "Batch file not found: $BatFilePath"
    }

    $lines = Get-Content -LiteralPath $BatFilePath
    $results = @()

    # Regex for winget pin add --id <ID>
    $wingetPattern = '^\s*winget\s+pin\s+add\s+--id\s+(\S+)'
    # Regex for choco pin add -n=<name> or --name=<name>
    $chocoPattern = '^\s*choco\s+pin\s+add\s+(?:-n|--name)=(\S+)'

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNumber = $i + 1  # 1-based

        if ($line -match $wingetPattern) {
            $results += [PSCustomObject]@{
                Id         = $Matches[1]
                Manager    = 'winget'
                LineNumber = $lineNumber
            }
        }
        elseif ($line -match $chocoPattern) {
            $results += [PSCustomObject]@{
                Id         = $Matches[1]
                Manager    = 'choco'
                LineNumber = $lineNumber
            }
        }
    }

    return $results
}

function Set-PinListInBat {
    <#
    .SYNOPSIS
        Writes pin entries back to the Update_Engine batch file's pin section.
    .DESCRIPTION
        Input: path to the .bat file and array of pin PSCustomObjects (Id, Manager).
        Rewrites the pin section while preserving all other content unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatFilePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Pins
    )

    if (-not (Test-Path -LiteralPath $BatFilePath)) {
        throw "Batch file not found: $BatFilePath"
    }

    $lines = Get-Content -LiteralPath $BatFilePath

    # Find the pin section boundaries
    # The pin section starts at the "echo [pins]" line
    # and ends just before the next "rem --" section header that isn't part of pins
    $pinSectionStart = -1
    $pinSectionEnd = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*echo\s+\[pins\]') {
            $pinSectionStart = $i
            break
        }
    }

    if ($pinSectionStart -lt 0) {
        throw "Could not find pin section (echo [pins]) in batch file: $BatFilePath"
    }

    # Find the end of the pin section: look for the next "rem --" section divider
    # that comes after the pin block (skip any rem lines that are comments within the pin section)
    $inPinBlock = $true
    for ($i = $pinSectionStart + 1; $i -lt $lines.Count; $i++) {
        # The pin section ends when we hit the next major section separator
        # Major sections start with "rem -- <Title>" pattern (with dashes after)
        if ($lines[$i] -match '^rem\s+--\s+\w' -and -not ($lines[$i] -match '(?i)pin')) {
            $pinSectionEnd = $i
            break
        }
    }

    if ($pinSectionEnd -lt 0) {
        # If no next section found, pin section goes to end of file
        $pinSectionEnd = $lines.Count
    }

    # Build the new pin section
    $wingetPins = @($Pins | Where-Object { $_.Manager -eq 'winget' })
    $chocoPins = @($Pins | Where-Object { $_.Manager -eq 'choco' })

    $newPinLines = @()
    $newPinLines += 'echo [pins] Pinning packages in winget and chocolatey...'

    if ($wingetPins.Count -gt 0) {
        $newPinLines += 'where winget >nul 2>&1 && ('
        foreach ($pin in $wingetPins) {
            $newPinLines += "    winget pin add --id $($pin.Id) --accept-source-agreements >nul 2>&1"
        }
        $newPinLines += ')'
    }

    if ($chocoPins.Count -gt 0) {
        $newPinLines += 'where choco >nul 2>&1 && ('
        foreach ($pin in $chocoPins) {
            $newPinLines += "    choco pin add -n=$($pin.Id)              >nul 2>&1"
        }
        $newPinLines += ')'
    }

    # Add a blank line before the next section
    $newPinLines += ''

    # Reconstruct the file: before pin section + new pin section + after pin section
    $before = @()
    if ($pinSectionStart -gt 0) {
        $before = $lines[0..($pinSectionStart - 1)]
    }
    $after = @()
    if ($pinSectionEnd -lt $lines.Count) {
        $after = $lines[$pinSectionEnd..($lines.Count - 1)]
    }

    $newContent = @()
    $newContent += $before
    $newContent += $newPinLines
    $newContent += $after

    # Default = system ANSI codepage, no BOM. ASCII would silently mangle any
    # future non-ASCII comment character to '?'; a UTF-8 BOM would break cmd's
    # parsing of the first line. ANSI is what cmd natively reads.
    Set-Content -LiteralPath $BatFilePath -Value $newContent -Encoding Default
}

function Test-PinId {
    <#
    .SYNOPSIS
        Validates a candidate pin ID for format correctness and uniqueness.
    .DESCRIPTION
        Input: candidate string, manager type ("winget" or "choco"), existing pin list.
        Validates: non-empty, no whitespace, format match (winget: dot-separated segments
        of alphanumeric/hyphen; choco: alphanumeric/hyphen only), not duplicate.
        Output: PSCustomObject with Valid ($true/$false) and Reason (string or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet("winget", "choco")]
        [string]$Manager,

        [Parameter()]
        [array]$ExistingPins = @()
    )

    # Check 1: Non-empty
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return [PSCustomObject]@{ Valid = $false; Reason = "Pin ID cannot be empty" }
    }

    # Check 2: No whitespace
    if ($Id -match '\s') {
        return [PSCustomObject]@{ Valid = $false; Reason = "Pin ID cannot contain whitespace" }
    }

    # Check 3: Format match
    switch ($Manager) {
        'winget' {
            if ($Id -notmatch '^\w[\w\-]+(\.[\w\-]+)+$') {
                return [PSCustomObject]@{ Valid = $false; Reason = "Pin ID does not match expected format for winget" }
            }
        }
        'choco' {
            if ($Id -notmatch '^[\w\-]+$') {
                return [PSCustomObject]@{ Valid = $false; Reason = "Pin ID does not match expected format for choco" }
            }
        }
    }

    # Check 4: Not duplicate
    foreach ($pin in $ExistingPins) {
        if ($pin.Id -eq $Id -and $pin.Manager -eq $Manager) {
            return [PSCustomObject]@{ Valid = $false; Reason = "Pin ID already exists for $Manager" }
        }
    }

    # All checks passed
    return [PSCustomObject]@{ Valid = $true; Reason = $null }
}

function New-ToastContent {
    <#
    .SYNOPSIS
        Constructs toast notification title and body from category statuses.
    .DESCRIPTION
        Input: hashtable of category name to status string ("ok" or "error").
        Output: PSCustomObject with Title and Body properties.
        Title contains "success" if all statuses are "ok", otherwise indicates "issues".
        Body lists each category with its status, sorted alphabetically by category name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CategoryStatuses
    )

    # Determine title based on whether all statuses are "ok" (case-insensitive)
    $allOk = $true
    foreach ($status in $CategoryStatuses.Values) {
        if ($status -ne 'ok') {
            $allOk = $false
            break
        }
    }

    if ($allOk) {
        $title = "Update Complete - All Successful"
    } else {
        $title = "Update Complete - Issues Detected"
    }

    # Build body: each category name paired with its status, sorted alphabetically
    $bodyLines = $CategoryStatuses.GetEnumerator() |
        Sort-Object -Property Name |
        ForEach-Object { "$($_.Name): $($_.Value)" }

    $body = $bodyLines -join "`n"

    [PSCustomObject]@{
        Title = $title
        Body  = $body
    }
}

function Send-CompletionToast {
    <#
    .SYNOPSIS
        Displays a Windows toast notification using the WinRT ToastNotificationManager API.
    .DESCRIPTION
        Sends a toast notification with the specified title and body text.
        Uses the WinRT ToastNotificationManager API (same mechanism used by the Update_Engine).
        Gracefully catches missing WinRT assemblies on systems that do not support them
        (older Windows, missing runtime components) — logs a verbose warning but never crashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Body
    )

    try {
        # Load WinRT assemblies required for toast notifications
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        # Build the toast XML template
        $toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Body</text>
    </binding>
  </visual>
</toast>
"@

        # Create XmlDocument and load the toast XML
        $xmlDoc = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xmlDoc.LoadXml($toastXml)

        # Create and show the toast notification
        $notification = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("UpdateDashboard")
        $notifier.Show($notification)
    }
    catch {
        Write-Verbose "Toast notification unavailable: $($_.Exception.Message)"
    }
}

function ConvertFrom-PnpUtilOutput {
    <#
    .SYNOPSIS
        Parses pnputil /enum-drivers text output into structured driver objects.
    .DESCRIPTION
        Input: raw pnputil text output string.
        Output: array of PSCustomObjects with PublishedName, ClassName, DriverVersion, DriverDate,
        sorted alphabetically by ClassName (case-insensitive) then by PublishedName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PnpUtilText
    )

    if ([string]::IsNullOrWhiteSpace($PnpUtilText)) {
        return @()
    }

    # Split on blank lines to get individual driver blocks
    # Normalize line endings first, then split on double newlines
    $normalized = $PnpUtilText -replace '\r\n', "`n"
    $blocks = $normalized -split '\n\s*\n'

    $drivers = @()

    foreach ($block in $blocks) {
        $block = $block.Trim()
        if ([string]::IsNullOrWhiteSpace($block)) { continue }

        # Only process blocks that contain "Published Name:" — skip header blocks
        if ($block -notmatch 'Published Name\s*:') { continue }

        $publishedName = $null
        $className = $null
        $driverVersion = $null
        $driverDate = $null

        $lines = $block -split '\n'
        foreach ($line in $lines) {
            if ($line -match '^\s*Published Name\s*:\s*(.+?)\s*$') {
                $publishedName = $Matches[1]
            }
            elseif ($line -match '^\s*Class Name\s*:\s*(.+?)\s*$') {
                $className = $Matches[1]
            }
            elseif ($line -match '^\s*Driver Version\s*:\s*(.+?)\s*$') {
                $versionFull = $Matches[1]
                # Format is "MM/DD/YYYY version" — extract date and version parts
                if ($versionFull -match '^\s*(\d{1,2}/\d{1,2}/\d{4})\s+(.+?)\s*$') {
                    $driverDate = $Matches[1]
                    $driverVersion = $Matches[2]
                }
                else {
                    # If format doesn't match expected pattern, use full value
                    $driverVersion = $versionFull
                    $driverDate = $null
                }
            }
        }

        # Only add if we got at least a published name
        if ($publishedName) {
            $drivers += [PSCustomObject]@{
                PublishedName = $publishedName
                ClassName     = $className
                DriverVersion = $driverVersion
                DriverDate    = $driverDate
            }
        }
    }

    # Sort by ClassName (case-insensitive) then by PublishedName
    $sorted = $drivers | Sort-Object @{Expression={$_.ClassName}; Ascending=$true}, @{Expression={$_.PublishedName}; Ascending=$true}

    # Ensure we always return an array
    return @($sorted)
}

function Start-SDIOGui {
    <#
    .SYNOPSIS
        Launches the Snappy Driver Installer Origin GUI matching the OS architecture.
    .DESCRIPTION
        Resolves whether the OS is 64-bit or 32-bit, selects the appropriate SDIO executable
        (SDIO_x64.exe or SDIO_x86.exe), validates that the file exists at the given base path,
        and launches it with no automation flags (full GUI mode).
        Returns the process handle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SDIOPath
    )

    $fullPath = Resolve-SDIOExecutable -SDIOPath $SDIOPath

    # Launch SDIO GUI with no flags (full GUI mode)
    $process = Start-Process -FilePath $fullPath -WorkingDirectory (Split-Path $fullPath -Parent) -PassThru
    return $process
}

function Resolve-SDIOExecutable {
    <#
    .SYNOPSIS
        Resolves the architecture-appropriate SDIO executable inside a directory.
    .DESCRIPTION
        SDIO release builds carry the version in the filename (e.g. SDIO_x64_R830.exe),
        so an exact name match breaks on every release. Match by pattern instead:
        SDIO_x64*.exe on 64-bit Windows, SDIO_x86*.exe (or plain SDIO*.exe) on 32-bit.
        Accepts either a directory or a direct path to the exe. Throws if nothing matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SDIOPath
    )

    # Direct path to an exe is accepted as-is
    if ($SDIOPath -match '\.exe$' -and (Test-Path -LiteralPath $SDIOPath)) {
        return $SDIOPath
    }

    if (-not (Test-Path -LiteralPath $SDIOPath)) {
        throw "SDIO path not found: $SDIOPath"
    }

    $patterns = if ([Environment]::Is64BitOperatingSystem) {
        @('SDIO_x64*.exe', 'SDIO_x64.exe')
    } else {
        @('SDIO_x86*.exe', 'SDIO.exe')
    }

    foreach ($pattern in $patterns) {
        $exe = Get-ChildItem -Path $SDIOPath -Filter $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }

    throw "No SDIO executable matching '$($patterns[0])' found in: $SDIOPath"
}

function Start-SDIOScan {
    <#
    .SYNOPSIS
        Runs an unattended SDIO scan with install suppressed, capturing output.
    .DESCRIPTION
        Resolves the architecture-specific SDIO executable, runs it with flags:
        -autoinstall -disableinstall -autoclose -nogui -verbose:1
        (install step suppressed via -disableinstall). Uses a 120-second watchdog;
        if the process doesn't exit within that time, it is killed.
        Captures output and returns the last 50 lines via Get-TailLines.
        Returns a PSCustomObject with Success, TimedOut, Output, and ExitCode properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SDIOPath
    )

    $fullPath = Resolve-SDIOExecutable -SDIOPath $SDIOPath

    # Create a temp file to capture redirected stdout
    $stdOutPath = [System.IO.Path]::GetTempFileName()

    $timedOut = $false
    $exitCode = -1
    $outputLines = @()

    try {
        # Start the SDIO process with scan flags (install suppressed)
        $process = Start-Process -FilePath $fullPath `
            -ArgumentList '-autoinstall', '-disableinstall', '-autoclose', '-nogui', '-verbose:1' `
            -RedirectStandardOutput $stdOutPath `
            -PassThru `
            -NoNewWindow

        # 120-second watchdog
        $completed = $process.WaitForExit(120000)

        if (-not $completed) {
            # Process did not exit within 120 seconds — kill it
            $timedOut = $true
            try { $process.Kill() } catch { }
            $exitCode = -1
        } else {
            $exitCode = $process.ExitCode
        }

        # Capture output from the temp file
        if (Test-Path -LiteralPath $stdOutPath) {
            $rawLines = Get-Content -LiteralPath $stdOutPath -ErrorAction SilentlyContinue
            if ($rawLines) {
                $outputLines = Get-TailLines -Lines $rawLines -Limit 50
            }
        }
    }
    finally {
        # Clean up temp file
        if (Test-Path -LiteralPath $stdOutPath) {
            Remove-Item -LiteralPath $stdOutPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Determine success: not timed out and exit code 0 and we got some output
    $success = (-not $timedOut) -and ($exitCode -eq 0) -and ($outputLines.Count -gt 0)

    [PSCustomObject]@{
        Success  = [bool]$success
        TimedOut = [bool]$timedOut
        Output   = [string[]]$outputLines
        ExitCode = [int]$exitCode
    }
}

function Start-NVCleanstall {
    <#
    .SYNOPSIS
        Launches NVCleanstall as a separate process.
    .DESCRIPTION
        Validates that the NVCleanstall executable exists at the given path.
        If not found, throws an error suggesting the TechPowerUp download page.
        Launches the application and returns the process handle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NVCleanstallPath
    )

    # Validate the executable exists
    if (-not (Test-Path -LiteralPath $NVCleanstallPath)) {
        throw "NVCleanstall not found at path: $NVCleanstallPath. Download it from https://www.techpowerup.com/download/techpowerup-nvcleanstall/"
    }

    # Launch NVCleanstall as a separate process
    $process = Start-Process -FilePath $NVCleanstallPath -PassThru
    return $process
}

function Test-NvidiaGPU {
    <#
    .SYNOPSIS
        Detects whether an NVIDIA GPU is present in the system.
    .DESCRIPTION
        Queries Win32_VideoController via Get-CimInstance and checks if any
        video controller's Name contains "NVIDIA". Returns $true if found, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
        if ($controllers) {
            $hasNvidia = $controllers | Where-Object { $_.Name -match 'NVIDIA' }
            return [bool]$hasNvidia
        }
    }
    catch {
        # If CIM query fails, assume no NVIDIA GPU
    }

    return $false
}

function Start-UpdateEngine {
    <#
    .SYNOPSIS
        Starts the Update_Engine batch script as an external process with skip flags.
    .DESCRIPTION
        Validates the engine path exists, sets DASHBOARD_SKIP_* environment variables
        from the provided SkipFlags hashtable, then launches the engine via cmd.exe
        with stdout/stderr redirected to temp files. Returns a PSCustomObject with the
        process handle and paths to the output files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SkipFlags,

        [Parameter(Mandatory)]
        [string]$EnginePath
    )

    # Validate engine path exists
    if (-not (Test-Path -LiteralPath $EnginePath)) {
        throw "Update engine not found at path: $EnginePath"
    }

    # Clear any stale skip flags from a previous run first — SkipFlags only contains
    # keys for UNCHECKED categories, so a leftover flag from an earlier run would
    # silently skip a category the user has since re-checked.
    foreach ($staleKey in @('DASHBOARD_SKIP_WINUPDATE', 'DASHBOARD_SKIP_STORE', 'DASHBOARD_SKIP_APPS', 'DASHBOARD_SKIP_STEAM')) {
        [System.Environment]::SetEnvironmentVariable($staleKey, $null, 'Process')
    }

    # Set environment variables for each DASHBOARD_SKIP_* key
    foreach ($key in $SkipFlags.Keys) {
        if ($key -like 'DASHBOARD_SKIP_*') {
            [System.Environment]::SetEnvironmentVariable($key, $SkipFlags[$key], 'Process')
        }
    }

    # Create temp files for stdout and stderr redirection
    $stdOutPath = [System.IO.Path]::GetTempFileName()
    $stdErrPath = [System.IO.Path]::GetTempFileName()

    # Start the engine process
    $process = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/c', $EnginePath `
        -RedirectStandardOutput $stdOutPath `
        -RedirectStandardError $stdErrPath `
        -PassThru `
        -NoNewWindow

    # Return process handle and output file paths
    [PSCustomObject]@{
        Process    = $process
        StdOutPath = $stdOutPath
        StdErrPath = $stdErrPath
    }
}

function Get-DriverStoreList {
    <#
    .SYNOPSIS
        Queries the Windows driver store via pnputil /enum-drivers with a 30-second timeout.
    .DESCRIPTION
        Starts pnputil /enum-drivers as a child process with stdout redirected to a temp file.
        Waits up to 30 seconds for completion. On success, reads the output and pipes it
        through ConvertFrom-PnpUtilOutput. On timeout or failure, returns the previous list.
        Returns a PSCustomObject with Success, TimedOut, Drivers, and ErrorMessage properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [array]$PreviousList = @()
    )

    $stdOutPath = [System.IO.Path]::GetTempFileName()

    try {
        # Start pnputil with stdout redirected to temp file
        $process = Start-Process -FilePath 'pnputil' `
            -ArgumentList '/enum-drivers' `
            -RedirectStandardOutput $stdOutPath `
            -PassThru `
            -NoNewWindow

        # Wait for the process with a 30-second timeout
        $completed = $process.WaitForExit(30000)

        if (-not $completed) {
            # Timeout: kill the process and return previous list
            try { $process.Kill() } catch { }
            return [PSCustomObject]@{
                Success      = $false
                TimedOut     = $true
                Drivers      = $PreviousList
                ErrorMessage = "Driver store query timed out after 30 seconds"
            }
        }

        $exitCode = $process.ExitCode

        if ($exitCode -ne 0) {
            # Non-zero exit code: return previous list
            return [PSCustomObject]@{
                Success      = $false
                TimedOut     = $false
                Drivers      = $PreviousList
                ErrorMessage = "pnputil failed with exit code: $exitCode"
            }
        }

        # Success: read output and parse
        $rawOutput = Get-Content -LiteralPath $stdOutPath -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($rawOutput)) {
            $rawOutput = ''
        }

        $result = ConvertFrom-PnpUtilOutput -PnpUtilText $rawOutput

        return [PSCustomObject]@{
            Success      = $true
            TimedOut     = $false
            Drivers      = $result
            ErrorMessage = $null
        }
    }
    catch {
        # Unexpected error: return previous list
        return [PSCustomObject]@{
            Success      = $false
            TimedOut     = $false
            Drivers      = $PreviousList
            ErrorMessage = "Unexpected error: $($_.Exception.Message)"
        }
    }
    finally {
        # Clean up temp file
        if (Test-Path -LiteralPath $stdOutPath) {
            Remove-Item -LiteralPath $stdOutPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PendingRebootStatus {
    <#
    .SYNOPSIS
        Checks standard Windows pending reboot indicators.
    .DESCRIPTION
        Checks three registry locations that signal a pending reboot:
        - CBS RebootPending key
        - Windows Update Auto Update RebootRequired key
        - Session Manager PendingFileRenameOperations value
        Each check is wrapped in try/catch so that access-denied or missing keys
        are treated as not-set. Returns a PSCustomObject with individual booleans
        and a combined IsRebootPending flag.
    #>
    [CmdletBinding()]
    param()

    # Check CBS RebootPending
    $cbs = $false
    try {
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    }
    catch {
        $cbs = $false
    }

    # Check Windows Update RebootRequired
    $wu = $false
    try {
        $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    catch {
        $wu = $false
    }

    # Check PendingFileRenameOperations
    $pfr = $false
    try {
        $val = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        $pfr = ($null -ne $val -and $val.Count -gt 0)
    }
    catch {
        $pfr = $false
    }

    [PSCustomObject]@{
        IsRebootPending  = [bool]($cbs -or $wu -or $pfr)
        CBS              = [bool]$cbs
        WindowsUpdate    = [bool]$wu
        PendingFileRename = [bool]$pfr
    }
}

function Get-AutoDiscoveredToolPaths {
    <#
    .SYNOPSIS
        Probes well-known install locations for the external tools the dashboard launches.
    .DESCRIPTION
        Returns a hashtable of tool name to discovered path (directory for SDIO/JDownloader,
        exe for the others). Keys with no hit are empty strings. Winget portable packages
        land under %LOCALAPPDATA%\Microsoft\WinGet\Packages\<Publisher.Name>_<source-hash>,
        so those are probed with wildcards.
    #>
    [CmdletBinding()]
    param()

    $result = @{
        SDIOPath        = ''
        NVCleanPath     = ''
        RAPRPath        = ''
        JDownloaderPath = ''
        SteamPath       = ''
    }

    $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'

    # SDIO: winget portable package dir, then classic extract locations
    $sdioCandidates = @(
        (Join-Path $wingetPackages 'GlennDelahoy.SnappyDriverInstallerOrigin_*')
        'C:\SDIO'
        (Join-Path $env:ProgramFiles 'SDIO')
    )
    foreach ($candidate in $sdioCandidates) {
        $dir = Get-Item -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dir -and (Get-ChildItem -Path $dir.FullName -Filter 'SDIO*.exe' -File -ErrorAction SilentlyContinue)) {
            $result.SDIOPath = $dir.FullName
            break
        }
    }

    # NVCleanstall: Program Files install or winget portable package
    $nvCandidates = @(
        (Join-Path $env:ProgramFiles 'NVCleanstall\NVCleanstall.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'NVCleanstall\NVCleanstall.exe')
        (Join-Path $wingetPackages 'TechPowerUp.NVCleanstall_*\NVCleanstall*.exe')
    )
    foreach ($candidate in $nvCandidates) {
        $exe = Get-Item -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { $result.NVCleanPath = $exe.FullName; break }
    }

    # DriverStoreExplorer (RAPR)
    $raprCandidates = @(
        (Join-Path $env:ProgramFiles 'Rapr\Rapr.exe')
        (Join-Path $wingetPackages 'lostindark.DriverStoreExplorer_*\Rapr.exe')
    )
    foreach ($candidate in $raprCandidates) {
        $exe = Get-Item -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { $result.RAPRPath = $exe.FullName; break }
    }

    # JDownloader 2: installation directory (contains JDownloader.jar)
    $jdCandidates = @(
        'C:\Program Files\JDownloader'
        'C:\Program Files (x86)\JDownloader'
        (Join-Path $env:LOCALAPPDATA 'JDownloader 2.0')
    )
    foreach ($candidate in $jdCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'JDownloader.jar')) {
            $result.JDownloaderPath = $candidate
            break
        }
    }

    # Steam: registry InstallPath, then default location
    try {
        $steamReg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
        if ($steamReg -and $steamReg.InstallPath -and (Test-Path -LiteralPath (Join-Path $steamReg.InstallPath 'steam.exe'))) {
            $result.SteamPath = $steamReg.InstallPath
        }
    } catch { }
    if (-not $result.SteamPath -and (Test-Path -LiteralPath 'C:\Program Files (x86)\Steam\steam.exe')) {
        $result.SteamPath = 'C:\Program Files (x86)\Steam'
    }

    return $result
}

function Get-DashboardSettings {
    <#
    .SYNOPSIS
        Loads dashboard settings from settings.json, filling gaps via autodiscovery.
    .DESCRIPTION
        Reads the JSON settings file if present and overlays it on the defaults.
        Any tool path left empty (or pointing at a location that no longer exists)
        is re-resolved through Get-AutoDiscoveredToolPaths, so a fresh machine works
        with zero manual configuration. Returns a hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath
    )

    $settings = @{
        SDIOPath              = ''
        NVCleanPath           = ''
        RAPRPath              = ''
        JDownloaderPath       = ''
        SteamPath             = ''
        SDIOScanTimeoutSec    = 120
        DriverQueryTimeoutSec = 30
        StaleOutputWarnSec    = 120
    }

    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $loaded = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                if ($settings.ContainsKey($prop.Name)) {
                    # Known key: only accept a non-empty value over the default
                    if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                        $settings[$prop.Name] = $prop.Value
                    }
                }
                else {
                    # Unknown key (e.g. the Rust GUI's NVCleanPackagePath /
                    # WinutilCommand): preserve verbatim so a save from this
                    # dashboard never strips another tool's configuration.
                    $settings[$prop.Name] = $prop.Value
                }
            }
        }
        catch {
            Write-Verbose "Failed to parse settings file, using defaults: $($_.Exception.Message)"
        }
    }

    # Autodiscover any path that is unset or dangling
    $pathKeys = @('SDIOPath', 'NVCleanPath', 'RAPRPath', 'JDownloaderPath', 'SteamPath')
    $needsDiscovery = $pathKeys | Where-Object {
        -not $settings[$_] -or -not (Test-Path -LiteralPath $settings[$_] -ErrorAction SilentlyContinue)
    }
    if ($needsDiscovery) {
        $discovered = Get-AutoDiscoveredToolPaths
        foreach ($key in $needsDiscovery) {
            if ($discovered[$key]) { $settings[$key] = $discovered[$key] }
        }
    }

    return $settings
}

function Save-DashboardSettings {
    <#
    .SYNOPSIS
        Persists dashboard settings to settings.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,

        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}
