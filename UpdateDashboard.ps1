#Requires -Version 5.1
<#
.SYNOPSIS
    Update Dashboard - WPF GUI wrapper for SystemUpdate_Topgrade.bat
.DESCRIPTION
    Single-file PowerShell 5.1 WPF dashboard following the winutil reference architecture.
    Uses a synchronized hashtable shared across a RunspacePool for background execution.
#>

# --- STA Threading Enforcement ---
# WPF requires STA (Single-Threaded Apartment) mode.
# If the current thread is not STA, re-launch the script with -STA.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $scriptPath = $MyInvocation.MyCommand.Definition
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) -NoNewWindow
    return
}

# --- Load WPF Assemblies ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --- Initialize Synchronized State Hashtable ---
$sync = [Hashtable]::Synchronized(@{
    # UI References
    Form           = $null          # [System.Windows.Window] WPF form
    RunspacePool   = $null          # [RunspacePool]

    # Runtime State
    IsRunning      = $false         # Guards against overlapping runs
    RunStartTime   = $null          # [DateTime] for elapsed display
    LastOutputTime = $null          # [DateTime] for stale-output detection

    # Category Status (idle | running | ok | error)
    CategoryStatus = @{
        WindowsUpdate = 'idle'
        Store         = 'idle'
        Apps          = 'idle'
        Drivers       = 'idle'
    }

    # Log Buffer
    LogLines       = [System.Collections.Generic.List[string]]::new()
    LogMaxLines    = 10000

    # Summary (populated after run)
    Summary        = $null          # [PSCustomObject] parsed from engine output
    EngineExitCode = $null          # [int] engine process exit code (null until a run completes)

    # Configuration
    EnginePath     = ''             # Resolved path to .bat
    SDIOPath       = ''             # User-configurable
    NVCleanPath    = ''             # User-configurable
    RAPRPath       = ''             # Optional DriverStoreExplorer path
    HasNvidiaGPU   = $false         # Detected at startup

    # Pending Reboot
    RebootStatus   = $null          # [PSCustomObject] from Get-PendingRebootStatus

    # Pin List
    Pins           = @()            # Array of pin objects
})

# --- Dot-source pure logic functions ---
. "$PSScriptRoot\Functions.ps1"

# --- Load settings (settings.json next to the script; autodiscovers tool paths) ---
$sync.SettingsPath = Join-Path $PSScriptRoot 'settings.json'
$sync.Settings = Get-DashboardSettings -SettingsPath $sync.SettingsPath
$sync.SDIOPath    = $sync.Settings.SDIOPath
$sync.NVCleanPath = $sync.Settings.NVCleanPath
$sync.RAPRPath    = $sync.Settings.RAPRPath

# Persist so the user has a file to edit (first run creates it with discovered paths)
try { Save-DashboardSettings -SettingsPath $sync.SettingsPath -Settings $sync.Settings } catch { }

# --- Read-EngineOutput Runspace ScriptBlock ---
# Runs in a background runspace to stream engine stdout into the shared $sync state.
# Parameters:
#   $sync       - the synchronized hashtable (shared state)
#   $stdOutPath - path to the file where engine stdout is redirected
$script:ReadEngineOutputBlock = {
    param($sync, $stdOutPath)

    try {
        # Wait for the stdout file to exist (retry up to 10 times with 500ms delay)
        $retries = 10
        while (-not (Test-Path -LiteralPath $stdOutPath) -and $retries -gt 0) {
            Start-Sleep -Milliseconds 500
            $retries--
        }

        if (-not (Test-Path -LiteralPath $stdOutPath)) {
            Add-LogLine -Buffer $sync.LogLines -Line "[Dashboard] ERROR: Engine output file not found: $stdOutPath"
            return
        }

        # Open a StreamReader on the stdout file
        $stream = [System.IO.FileStream]::new(
            $stdOutPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = [System.IO.StreamReader]::new($stream)

        # Summary collection state. The engine's opening BANNER is also two
        # ======== lines, so a ======== line only opens a summary block if the
        # NEXT line starts with "Summary" - otherwise both lines are plain log.
        $inSummary = $false
        $pendingOpen = $false
        $pendingLine = $null
        $summaryLines = [System.Collections.Generic.List[string]]::new()

        # Read loop: continue until the engine process has exited AND no more data
        while ($true) {
            $line = $reader.ReadLine()

            if ($null -ne $line) {
                # Append to the log buffer
                Add-LogLine -Buffer $sync.LogLines -Line $line

                # Check for category marker
                $category = Get-CategoryFromMarker -Line $line
                if ($null -ne $category) {
                    $sync.CategoryStatus[$category] = 'running'
                }

                # Detect summary block boundaries (lines starting with ========)
                if ($line -match '^========') {
                    if ($inSummary) {
                        # Exiting summary block (closing ======== line)
                        $summaryLines.Add($line)
                        $inSummary = $false

                        # Parse the collected summary
                        $summaryText = $summaryLines -join "`n"
                        $sync.Summary = ConvertFrom-EngineSummary -SummaryText $summaryText
                    }
                    else {
                        # Might be a summary opener - or just the banner. Decide
                        # when the next line arrives.
                        $pendingOpen = $true
                        $pendingLine = $line
                    }
                }
                elseif ($pendingOpen) {
                    $pendingOpen = $false
                    if ($line -match '^\s*Summary') {
                        # Real summary block: keep the held ======== plus this line
                        $inSummary = $true
                        $summaryLines.Clear()
                        $summaryLines.Add($pendingLine)
                        $summaryLines.Add($line)
                    }
                    # else: banner or decoration - both lines were already logged
                }
                elseif ($inSummary) {
                    # Accumulate lines within the summary block
                    $summaryLines.Add($line)
                }

                # Update last output time for stale-output detection
                $sync.LastOutputTime = [DateTime]::Now

                # Dispatch UI update via WPF Dispatcher (skip if Form is null, e.g., during testing)
                if ($null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher) {
                    $sync.Form.Dispatcher.Invoke([Action]{
                        # UI update logic will be wired in task 10.2
                        # For now this ensures the dispatcher pattern is in place
                    })
                }
            }
            else {
                # No line available — check if the engine process has exited
                if ($sync.IsRunning -eq $false) {
                    # Process has exited; do a final drain attempt
                    $finalLine = $reader.ReadLine()
                    if ($null -eq $finalLine) {
                        break
                    }
                    # If there was a final line, process it on next iteration
                    continue
                }

                # Process still running but no data yet — sleep briefly and retry
                Start-Sleep -Milliseconds 100
            }
        }

        # If we were collecting summary when output ended, parse what we have
        if ($inSummary -and $summaryLines.Count -gt 0) {
            $summaryText = $summaryLines -join "`n"
            $sync.Summary = ConvertFrom-EngineSummary -SummaryText $summaryText
        }

    }
    catch {
        # Log errors to the shared buffer so they appear in the GUI
        $errorMsg = "[Dashboard] Output reader error: $($_.Exception.Message)"
        if ($null -ne $sync -and $null -ne $sync.LogLines) {
            Add-LogLine -Buffer $sync.LogLines -Line $errorMsg
        }
    }
    finally {
        # Clean up stream resources
        if ($null -ne $reader) {
            try { $reader.Close() } catch { }
        }
        if ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

# --- RunspacePool Management Functions ---

function Initialize-RunspacePool {
    <#
    .SYNOPSIS
        Creates a RunspacePool (min=2, max=4) with $sync injected and all Functions.ps1 helpers registered.
    #>
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # Inject the $sync synchronized hashtable into the session state
    $syncEntry = [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('sync', $sync, 'Synchronized state hashtable')
    $iss.Variables.Add($syncEntry)

    # Register all pure functions from Functions.ps1 into the session state
    $functionsToRegister = @(
        'ConvertTo-SkipFlags'
        'Add-LogLine'
        'Get-CategoryFromMarker'
        'ConvertFrom-EngineSummary'
        'Get-TailLines'
        'Get-PinListFromBat'
        'Set-PinListInBat'
        'Test-PinId'
        'New-ToastContent'
        'Send-CompletionToast'
        'ConvertFrom-PnpUtilOutput'
        'Start-SDIOGui'
        'Start-SDIOScan'
        'Start-NVCleanstall'
        'Test-NvidiaGPU'
        'Start-UpdateEngine'
        'Get-DriverStoreList'
        'Get-PendingRebootStatus'
    )

    foreach ($funcName in $functionsToRegister) {
        $funcDef = Get-Content Function:\$funcName -ErrorAction SilentlyContinue
        if ($funcDef) {
            $funcEntry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($funcName, $funcDef.ToString())
            $iss.Commands.Add($funcEntry)
        }
    }

    # Create the RunspacePool with min=2, max=4
    $pool = [RunspaceFactory]::CreateRunspacePool(2, 4, $iss, $Host)
    $pool.Open()

    $sync.RunspacePool = $pool
}

function Invoke-BackgroundCommand {
    <#
    .SYNOPSIS
        Creates a PowerShell instance, assigns it to the RunspacePool, and invokes a scriptblock asynchronously.
    .PARAMETER ScriptBlock
        The scriptblock to execute in the background.
    .PARAMETER ArgumentList
        Optional arguments to pass to the scriptblock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList
    )

    $ps = [PowerShell]::Create()
    $ps.AddScript($ScriptBlock) | Out-Null

    if ($ArgumentList) {
        foreach ($arg in $ArgumentList) {
            $ps.AddArgument($arg) | Out-Null
        }
    }

    $ps.RunspacePool = $sync.RunspacePool
    $handle = $ps.BeginInvoke()

    [PSCustomObject]@{
        PowerShell = $ps
        Handle     = $handle
    }
}

function Close-RunspacePool {
    <#
    .SYNOPSIS
        Gracefully shuts down the RunspacePool on window close.
    #>
    if ($null -ne $sync.RunspacePool) {
        $sync.RunspacePool.Close()
        $sync.RunspacePool.Dispose()
        $sync.RunspacePool = $null
    }
}

# --- XAML UI Definition ---
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Update Dashboard"
    Height="700"
    Width="900"
    WindowStartupLocation="CenterScreen"
    Background="#1e1e1e">

    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#e0e0e0"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#e0e0e0"/>
            <Setter Property="Margin" Value="0,4,0,4"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#3a3a3a"/>
            <Setter Property="Foreground" Value="#e0e0e0"/>
            <Setter Property="BorderBrush" Value="#555555"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="0,4,0,4"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#e0e0e0"/>
        </Style>
    </Window.Resources>

    <DockPanel>
        <!-- Top Banner -->
        <StackPanel DockPanel.Dock="Top" Background="#2d2d2d" Margin="0,0,0,0">
            <TextBlock Text="System Update Dashboard"
                       FontSize="22" FontWeight="Bold"
                       Foreground="#ffffff"
                       Margin="16,12,16,8"/>
            <!-- Pending Reboot Warning Banner -->
            <Border x:Name="PnlRebootWarning" Visibility="Collapsed"
                    Background="#4d3800" BorderBrush="#ff9900" BorderThickness="0,1,0,1"
                    Padding="12,8">
                <StackPanel>
                    <TextBlock Text="⚠ Pending Reboot Detected" FontWeight="Bold"
                               Foreground="#ffcc00" FontSize="14"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <TextBlock x:Name="TxtRebootCBS" Text="CBS" Foreground="#ffcc00"
                                   Margin="0,0,12,0" Visibility="Collapsed"/>
                        <TextBlock x:Name="TxtRebootWU" Text="Windows Update" Foreground="#ffcc00"
                                   Margin="0,0,12,0" Visibility="Collapsed"/>
                        <TextBlock x:Name="TxtRebootPFR" Text="PendingFileRename" Foreground="#ffcc00"
                                   Margin="0,0,12,0" Visibility="Collapsed"/>
                    </StackPanel>
                    <TextBlock Text="A reboot is recommended before installing additional updates."
                               Foreground="#e0c060" FontSize="11" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>
        </StackPanel>

        <!-- Bottom Status Bar -->
        <Border DockPanel.Dock="Bottom" Background="#252525" BorderBrush="#3a3a3a"
                BorderThickness="0,1,0,0" Padding="12,6">
            <DockPanel>
                <TextBlock x:Name="TxtRunState" Text="Idle" DockPanel.Dock="Left"
                           Foreground="#aaaaaa" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtWaiting" Text="Waiting for output..."
                           DockPanel.Dock="Right" Foreground="#ff9900" FontSize="11"
                           VerticalAlignment="Center" Visibility="Collapsed" Margin="12,0,0,0"/>
                <TextBlock x:Name="TxtElapsed" Text="" DockPanel.Dock="Right"
                           Foreground="#aaaaaa" FontSize="12"
                           VerticalAlignment="Center" HorizontalAlignment="Right"/>
            </DockPanel>
        </Border>

        <!-- Main Content Area -->
        <Grid Margin="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="210"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Left Panel -->
            <Border Grid.Column="0" Background="#252525" BorderBrush="#3a3a3a"
                    BorderThickness="0,0,1,0" Padding="12,12">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <!-- Categories Section -->
                        <TextBlock Text="Categories" FontSize="14" FontWeight="SemiBold"
                                   Foreground="#ffffff" Margin="0,0,0,8"/>

                        <CheckBox x:Name="ChkWindowsUpdate" Content="Windows Update" IsChecked="True"/>
                        <TextBlock x:Name="StatusWindowsUpdate" Text="idle"
                                   FontSize="10" Foreground="#888888" Margin="18,0,0,6"/>

                        <CheckBox x:Name="ChkStore" Content="Microsoft Store" IsChecked="True"/>
                        <TextBlock x:Name="StatusStore" Text="idle"
                                   FontSize="10" Foreground="#888888" Margin="18,0,0,6"/>

                        <CheckBox x:Name="ChkApps" Content="Winget/Choco/Topgrade" IsChecked="True"/>
                        <TextBlock x:Name="StatusApps" Text="idle"
                                   FontSize="10" Foreground="#888888" Margin="18,0,0,6"/>

                        <CheckBox x:Name="ChkDrivers" Content="Drivers" IsChecked="True"/>
                        <TextBlock x:Name="StatusDrivers" Text="idle"
                                   FontSize="10" Foreground="#888888" Margin="18,0,0,6"/>

                        <!-- Run Button -->
                        <Button x:Name="BtnRun" Content="Run Selected"
                                FontSize="14" FontWeight="Bold"
                                Background="#2e7d32" Foreground="#ffffff"
                                BorderBrush="#43a047"
                                Padding="12,10" Margin="0,12,0,8"
                                HorizontalAlignment="Stretch"/>

                        <!-- Separator -->
                        <Separator Background="#3a3a3a" Margin="0,8,0,12"/>

                        <!-- Drivers Section -->
                        <TextBlock Text="Driver Tools" FontSize="13" FontWeight="SemiBold"
                                   Foreground="#ffffff" Margin="0,0,0,8"/>

                        <Button x:Name="BtnSDIO" Content="Launch SDIO"
                                HorizontalAlignment="Stretch"/>

                        <Button x:Name="BtnNVClean" Content="Launch NVCleanstall"
                                Visibility="Collapsed"
                                HorizontalAlignment="Stretch"/>

                        <CheckBox x:Name="ChkSDIOScan" Content="Advanced: SDIO Scan"
                                  IsChecked="False" Margin="0,8,0,4"/>

                        <TextBlock Text="NVCleanstall v1.19.0: reported compatibility issue with NVIDIA driver branches 595.xx–596.xx."
                                   FontSize="10" FontStyle="Italic"
                                   Foreground="#999999" TextWrapping="Wrap"
                                   Margin="0,8,0,0"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Center Panel -->
            <TabControl x:Name="TabMain" Grid.Column="1" Background="#1e1e1e"
                        BorderBrush="#3a3a3a" Margin="0">

                <!-- Log Tab -->
                <TabItem Header="Log">
                    <Border Background="#1a1a1a">
                        <ScrollViewer x:Name="ScrollLog" VerticalScrollBarVisibility="Auto"
                                      HorizontalScrollBarVisibility="Auto">
                            <TextBlock x:Name="TxtLog"
                                       FontFamily="Consolas" FontSize="12"
                                       Foreground="#cccccc" Background="#1a1a1a"
                                       Padding="8" TextWrapping="NoWrap"/>
                        </ScrollViewer>
                    </Border>
                </TabItem>

                <!-- Summary Tab -->
                <TabItem Header="Summary">
                    <Border Background="#1e1e1e" Padding="12">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel x:Name="PnlSummary">
                                <TextBlock Text="Run summary will appear here after a completed run."
                                           Foreground="#888888" FontStyle="Italic"/>
                            </StackPanel>
                        </ScrollViewer>
                    </Border>
                </TabItem>

                <!-- Pin Editor Tab -->
                <TabItem Header="Pin Editor">
                    <Border Background="#1e1e1e" Padding="12">
                        <DockPanel>
                            <!-- Pin list -->
                            <ListView x:Name="LstPins" DockPanel.Dock="Top"
                                      Background="#252525" Foreground="#e0e0e0"
                                      BorderBrush="#3a3a3a" Height="300"
                                      Margin="0,0,0,8">
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="Package ID" Width="320"
                                                        DisplayMemberBinding="{Binding Id}"/>
                                        <GridViewColumn Header="Manager" Width="120"
                                                        DisplayMemberBinding="{Binding Manager}"/>
                                    </GridView>
                                </ListView.View>
                            </ListView>

                            <!-- Add/Remove controls -->
                            <StackPanel DockPanel.Dock="Bottom">
                                <StackPanel Orientation="Horizontal" Margin="0,4,0,4">
                                    <TextBox x:Name="TxtNewPinId" Width="240"
                                             Background="#2a2a2a" Foreground="#e0e0e0"
                                             BorderBrush="#555555" Padding="4,3"
                                             ToolTip="Enter package ID"/>
                                    <ComboBox x:Name="CboManager" Width="100" Margin="8,0,0,0"
                                              Background="#2a2a2a" Foreground="#1e1e1e"
                                              BorderBrush="#555555" SelectedIndex="0">
                                        <ComboBoxItem Content="winget"/>
                                        <ComboBoxItem Content="choco"/>
                                    </ComboBox>
                                    <Button x:Name="BtnAddPin" Content="Add" Margin="8,0,0,0"/>
                                    <Button x:Name="BtnRemovePin" Content="Remove" Margin="4,0,0,0"/>
                                </StackPanel>
                                <Button x:Name="BtnSavePins" Content="Save Pins"
                                        HorizontalAlignment="Left" Margin="0,4,0,4"/>
                                <TextBlock x:Name="TxtPinError" Text=""
                                           Foreground="#ff4444" FontSize="11" Margin="0,4,0,0"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>
                </TabItem>

                <!-- Driver Store Tab -->
                <TabItem Header="Driver Store">
                    <Border Background="#1e1e1e" Padding="12">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                                <Button x:Name="BtnRefreshDrivers" Content="Refresh"/>
                                <Button x:Name="BtnRAPR" Content="Launch DriverStoreExplorer"
                                        Visibility="Collapsed" Margin="8,0,0,0"/>
                                <TextBlock x:Name="TxtDriversLoading" Text="Loading drivers..."
                                           Visibility="Collapsed" VerticalAlignment="Center"
                                           Foreground="#ff9900" Margin="12,0,0,0"/>
                            </StackPanel>
                            <DataGrid x:Name="DgDrivers" DockPanel.Dock="Bottom"
                                      AutoGenerateColumns="False" IsReadOnly="True"
                                      Background="#252525" Foreground="#e0e0e0"
                                      BorderBrush="#3a3a3a" RowBackground="#252525"
                                      AlternatingRowBackground="#2a2a2a"
                                      GridLinesVisibility="Horizontal"
                                      HorizontalGridLinesBrush="#3a3a3a"
                                      HeadersVisibility="Column" CanUserAddRows="False">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Published Name" Width="150"
                                                        Binding="{Binding PublishedName}"/>
                                    <DataGridTextColumn Header="Class" Width="120"
                                                        Binding="{Binding ClassName}"/>
                                    <DataGridTextColumn Header="Version" Width="150"
                                                        Binding="{Binding DriverVersion}"/>
                                    <DataGridTextColumn Header="Date" Width="100"
                                                        Binding="{Binding DriverDate}"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </TabItem>

            </TabControl>

        </Grid>
    </DockPanel>
</Window>
"@

# --- Parse XAML and Create Window ---
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$sync.Form = [Windows.Markup.XamlReader]::Load($reader)

# --- Get Named UI Elements ---
$chkWindowsUpdate   = $sync.Form.FindName('ChkWindowsUpdate')
$chkStore           = $sync.Form.FindName('ChkStore')
$chkApps            = $sync.Form.FindName('ChkApps')
$chkDrivers         = $sync.Form.FindName('ChkDrivers')

$btnRun             = $sync.Form.FindName('BtnRun')
$btnSDIO            = $sync.Form.FindName('BtnSDIO')
$btnNVClean         = $sync.Form.FindName('BtnNVClean')

$txtLog             = $sync.Form.FindName('TxtLog')
$scrollLog          = $sync.Form.FindName('ScrollLog')
$pnlSummary         = $sync.Form.FindName('PnlSummary')
$txtRunState        = $sync.Form.FindName('TxtRunState')
$txtElapsed         = $sync.Form.FindName('TxtElapsed')
$txtWaiting         = $sync.Form.FindName('TxtWaiting')

$pnlRebootWarning   = $sync.Form.FindName('PnlRebootWarning')
$txtRebootCBS       = $sync.Form.FindName('TxtRebootCBS')
$txtRebootWU        = $sync.Form.FindName('TxtRebootWU')
$txtRebootPFR       = $sync.Form.FindName('TxtRebootPFR')

$statusWindowsUpdate = $sync.Form.FindName('StatusWindowsUpdate')
$statusStore         = $sync.Form.FindName('StatusStore')
$statusApps          = $sync.Form.FindName('StatusApps')
$statusDrivers       = $sync.Form.FindName('StatusDrivers')

# --- Category Checkbox Change Handlers ---
# Enable/disable Run button based on whether at least one category is checked
$script:UpdateRunButtonState = {
    $anyChecked = $chkWindowsUpdate.IsChecked -or $chkStore.IsChecked -or $chkApps.IsChecked -or $chkDrivers.IsChecked
    $btnRun.IsEnabled = [bool]$anyChecked
}

$chkWindowsUpdate.Add_Checked($script:UpdateRunButtonState)
$chkWindowsUpdate.Add_Unchecked($script:UpdateRunButtonState)
$chkStore.Add_Checked($script:UpdateRunButtonState)
$chkStore.Add_Unchecked($script:UpdateRunButtonState)
$chkApps.Add_Checked($script:UpdateRunButtonState)
$chkApps.Add_Unchecked($script:UpdateRunButtonState)
$chkDrivers.Add_Checked($script:UpdateRunButtonState)
$chkDrivers.Add_Unchecked($script:UpdateRunButtonState)

# --- Auto-Scroll Behavior for Log Panel ---
$sync.UserScrolledUp = $false

$scrollLog.Add_ScrollChanged({
    param($sender, $e)
    # Check if user is at the bottom (within 1 pixel tolerance)
    $atBottom = ($sender.VerticalOffset -ge ($sender.ScrollableHeight - 1))
    if ($atBottom) {
        $sync.UserScrolledUp = $false
    }
    elseif ($e.VerticalChange -lt 0) {
        # User scrolled up
        $sync.UserScrolledUp = $true
    }
})

# Helper: auto-scroll to bottom if user hasn't scrolled up
$script:AutoScrollLog = {
    if (-not $sync.UserScrolledUp) {
        $scrollLog.ScrollToEnd()
    }
}

# --- Pending Reboot Check on Startup ---
$sync.RebootStatus = Get-PendingRebootStatus

if ($sync.RebootStatus.IsRebootPending) {
    $pnlRebootWarning.Visibility = [System.Windows.Visibility]::Visible
    if ($sync.RebootStatus.CBS) {
        $txtRebootCBS.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($sync.RebootStatus.WindowsUpdate) {
        $txtRebootWU.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($sync.RebootStatus.PendingFileRename) {
        $txtRebootPFR.Visibility = [System.Windows.Visibility]::Visible
    }
}

# --- Engine Path Resolution ---
$sync.EnginePath = Join-Path $PSScriptRoot 'SystemUpdate_Topgrade.bat'

if (-not (Test-Path -LiteralPath $sync.EnginePath)) {
    $btnRun.IsEnabled = $false
    $txtRunState.Text = "Error: Engine not found at $($sync.EnginePath)"
}

# --- NVIDIA GPU Detection ---
$sync.HasNvidiaGPU = Test-NvidiaGPU

if ($sync.HasNvidiaGPU) {
    $btnNVClean.Visibility = [System.Windows.Visibility]::Visible
}

# --- Pin List Loading on Startup ---
try {
    $sync.Pins = Get-PinListFromBat -BatFilePath $sync.EnginePath
}
catch {
    $sync.Pins = @()
}

# --- Run Button Click Handler ---
$btnRun.Add_Click({
    # Re-check pending reboot
    $sync.RebootStatus = Get-PendingRebootStatus

    # Update reboot warning banner
    if ($sync.RebootStatus.IsRebootPending) {
        $pnlRebootWarning.Visibility = [System.Windows.Visibility]::Visible
        $txtRebootCBS.Visibility = if ($sync.RebootStatus.CBS) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $txtRebootWU.Visibility = if ($sync.RebootStatus.WindowsUpdate) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $txtRebootPFR.Visibility = if ($sync.RebootStatus.PendingFileRename) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }

        # Show confirmation prompt
        $result = [System.Windows.MessageBox]::Show(
            "A pending reboot has been detected. Running updates in this state may cause issues.`n`nDo you want to proceed anyway?",
            "Pending Reboot Warning",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($result -eq [System.Windows.MessageBoxResult]::No) {
            return
        }
    }

    # Get category states from checkboxes
    $categories = @{
        WindowsUpdate = [bool]$chkWindowsUpdate.IsChecked
        Store         = [bool]$chkStore.IsChecked
        Apps          = [bool]$chkApps.IsChecked
        Drivers       = [bool]$chkDrivers.IsChecked
    }

    # Convert to skip flags
    $skipFlags = ConvertTo-SkipFlags -Categories $categories

    # Set running state
    $sync.IsRunning = $true
    $sync.RunStartTime = [DateTime]::Now
    $sync.LastOutputTime = [DateTime]::Now

    # Disable Run button and all checkboxes
    $btnRun.IsEnabled = $false
    $chkWindowsUpdate.IsEnabled = $false
    $chkStore.IsEnabled = $false
    $chkApps.IsEnabled = $false
    $chkDrivers.IsEnabled = $false

    # Update status display
    $txtRunState.Text = "Running..."
    $txtElapsed.Text = ""
    $txtWaiting.Visibility = [System.Windows.Visibility]::Collapsed

    # Clear log and summary
    $sync.LogLines.Clear()
    $txtLog.Text = ""
    $sync.Summary = $null
    $sync.EngineExitCode = $null

    # Reset category statuses
    $sync.CategoryStatus['WindowsUpdate'] = 'idle'
    $sync.CategoryStatus['Store'] = 'idle'
    $sync.CategoryStatus['Apps'] = 'idle'
    $sync.CategoryStatus['Drivers'] = 'idle'

    # Update status labels
    $statusWindowsUpdate.Text = 'idle'
    $statusStore.Text = 'idle'
    $statusApps.Text = 'idle'
    $statusDrivers.Text = 'idle'

    # --- Engine/Driver Execution Flow ---
    if ($skipFlags.InvokeEngine) {
        # Start engine in background runspace
        Invoke-BackgroundCommand -ScriptBlock {
            param($sync, $skipFlags, $categories, $ReadEngineOutputBlock)
            try {
                $engineResult = Start-UpdateEngine -SkipFlags $skipFlags -EnginePath $sync.EnginePath

                # Start output reader in another background runspace
                $readerPs = [PowerShell]::Create()
                $readerPs.AddScript($ReadEngineOutputBlock) | Out-Null
                $readerPs.AddArgument($sync) | Out-Null
                $readerPs.AddArgument($engineResult.StdOutPath) | Out-Null
                $readerPs.RunspacePool = $sync.RunspacePool
                $readerHandle = $readerPs.BeginInvoke()

                # Wait for engine process to exit
                $engineResult.Process.WaitForExit()
                $sync.EngineExitCode = $engineResult.Process.ExitCode
                $sync.IsRunning = $false

                # Wait for reader to finish draining output
                try { $readerPs.EndInvoke($readerHandle) } catch { }
                try { $readerPs.Dispose() } catch { }

                # Surface any stderr the engine produced, then clean up temp files
                try {
                    $errLines = Get-Content -LiteralPath $engineResult.StdErrPath -ErrorAction SilentlyContinue
                    foreach ($errLine in @($errLines | Where-Object { $_ })) {
                        Add-LogLine -Buffer $sync.LogLines -Line "[stderr] $errLine"
                    }
                } catch { }
                foreach ($tmp in @($engineResult.StdOutPath, $engineResult.StdErrPath)) {
                    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
                }

                # Clear skip flags so the next in-session run starts clean
                foreach ($flagKey in @('DASHBOARD_SKIP_WINUPDATE', 'DASHBOARD_SKIP_STORE', 'DASHBOARD_SKIP_APPS')) {
                    [System.Environment]::SetEnvironmentVariable($flagKey, $null, 'Process')
                }

                # Update category statuses based on summary.
                # Engine status values that do NOT indicate a failure:
                $benign = @('ok', 'skipped', 'n/a', 'reinstalled')
                if ($null -ne $sync.Summary) {
                    if ($null -ne $sync.Summary.WindowsUpdate) {
                        $sync.CategoryStatus['WindowsUpdate'] = if ($sync.Summary.WindowsUpdate -in $benign) { 'ok' } else { 'error' }
                    }
                    $appsFields = @($sync.Summary.Winget, $sync.Summary.Topgrade, $sync.Summary.EAApp,
                                    $sync.Summary.Steam, $sync.Summary.JDownloader) | Where-Object { $null -ne $_ }
                    if ($appsFields.Count -gt 0) {
                        $appsBad = @($appsFields | Where-Object { $_ -notin $benign })
                        $sync.CategoryStatus['Apps'] = if ($appsBad.Count -eq 0) { 'ok' } else { 'error' }
                    }
                    if ($null -ne $sync.Summary.Store -and $categories['Store']) {
                        $sync.CategoryStatus['Store'] = if ($sync.Summary.Store -in $benign) { 'ok' } else { 'error' }
                    }
                }
                # Fallback when the summary lacks a Store line (older engine): tie the
                # status to the engine exit code rather than assuming success.
                if ($categories['Store'] -and $sync.CategoryStatus['Store'] -eq 'idle') {
                    $sync.CategoryStatus['Store'] = if ($sync.EngineExitCode -eq 0) { 'ok' } else { 'error' }
                }

                # Fire toast notification
                $toast = New-ToastContent -CategoryStatuses $sync.CategoryStatus
                Send-CompletionToast -Title $toast.Title -Body $toast.Body

                # If Drivers was also checked, launch SDIO after engine completes
                if ($categories['Drivers']) {
                    if ($sync.SDIOPath -and (Test-Path -LiteralPath $sync.SDIOPath)) {
                        try { Start-SDIOGui -SDIOPath $sync.SDIOPath } catch { }
                        $sync.CategoryStatus['Drivers'] = 'ok'
                    } elseif ($sync.SDIOPath) {
                        $sync.CategoryStatus['Drivers'] = 'error'
                    }
                }

                # Re-enable UI via Dispatcher
                $sync.Form.Dispatcher.Invoke([Action]{ & $sync.OnRunCompleted })
            }
            catch {
                $errorMsg = $_.Exception.Message
                $sync.IsRunning = $false
                # Engine error — show message and re-enable
                $sync.Form.Dispatcher.Invoke([Action]{
                    [System.Windows.MessageBox]::Show(
                        "Engine error: $errorMsg",
                        'Update Engine Error',
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Error
                    ) | Out-Null
                    & $sync.OnRunCompleted
                })
            }
        } -ArgumentList @($sync, $skipFlags, $categories, $script:ReadEngineOutputBlock)
    }
    elseif ($categories['Drivers']) {
        # Drivers-only path: skip engine, launch SDIO directly
        try {
            if ($sync.SDIOPath -and (Test-Path -LiteralPath $sync.SDIOPath)) {
                Start-SDIOGui -SDIOPath $sync.SDIOPath
                $sync.CategoryStatus['Drivers'] = 'ok'
            }
            elseif ($sync.SDIOPath) {
                [System.Windows.MessageBox]::Show(
                    "SDIO not found at configured path: $($sync.SDIOPath)",
                    'Driver Tool Not Found',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                ) | Out-Null
                $sync.CategoryStatus['Drivers'] = 'error'
            }
            else {
                [System.Windows.MessageBox]::Show(
                    "SDIO path is not configured. Please set the SDIOPath in the dashboard configuration.",
                    'Driver Tool Not Configured',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                ) | Out-Null
            }
        }
        catch {
            [System.Windows.MessageBox]::Show(
                "Error launching SDIO: $($_.Exception.Message)",
                'Driver Tool Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        # Re-enable controls immediately (no background engine running)
        & $script:OnRunCompleted
    }
    else {
        # Nothing to do (should not reach here due to button disable logic)
        & $script:OnRunCompleted
    }
})

# --- Completion Helper (called from background runspace via Dispatcher) ---
$script:OnRunCompleted = {
    # Re-enable controls
    $btnRun.IsEnabled = $true
    $chkWindowsUpdate.IsEnabled = $true
    $chkStore.IsEnabled = $true
    $chkApps.IsEnabled = $true
    $chkDrivers.IsEnabled = $true

    # Update state
    $sync.IsRunning = $false
    $txtWaiting.Visibility = [System.Windows.Visibility]::Collapsed

    # Run-state reflects the engine's actual exit code, not just "Idle"
    if ($null -ne $sync.EngineExitCode) {
        if ($sync.EngineExitCode -eq 0) {
            $txtRunState.Text = 'Completed successfully'
        } else {
            $txtRunState.Text = "Failed (engine exit code $($sync.EngineExitCode))"
        }
    } else {
        $txtRunState.Text = 'Idle'
    }

    # Final log render — the elapsed timer stops updating once IsRunning is false,
    # so without this the tail of the log (including the summary block) never shows.
    $txtLog.Text = $sync.LogLines -join "`r`n"
    & $script:AutoScrollLog

    # Final category status labels
    $statusWindowsUpdate.Text = $sync.CategoryStatus['WindowsUpdate']
    $statusStore.Text = $sync.CategoryStatus['Store']
    $statusApps.Text = $sync.CategoryStatus['Apps']
    $statusDrivers.Text = $sync.CategoryStatus['Drivers']

    # Render the parsed summary into the Summary tab
    & $script:RenderSummaryPanel

    # Re-evaluate Run button state (in case no checkboxes are checked)
    & $script:UpdateRunButtonState
}

# --- Summary Panel Renderer ---
$script:RenderSummaryPanel = {
    $pnlSummary.Children.Clear()

    if ($null -eq $sync.Summary) {
        $placeholder = [System.Windows.Controls.TextBlock]::new()
        $placeholder.Text = 'No summary was produced by this run.'
        $placeholder.Foreground = '#888888'
        $placeholder.FontStyle = 'Italic'
        $pnlSummary.Children.Add($placeholder) | Out-Null
        return
    }

    $rows = @(
        @{ Label = 'winget';         Value = $sync.Summary.Winget }
        @{ Label = 'topgrade';       Value = $sync.Summary.Topgrade }
        @{ Label = 'Windows Update'; Value = $sync.Summary.WindowsUpdate }
        @{ Label = 'Store';          Value = $sync.Summary.Store }
        @{ Label = 'Steam games';    Value = $sync.Summary.Steam }
        @{ Label = 'JDownloader';    Value = $sync.Summary.JDownloader }
        @{ Label = 'EA app';         Value = $sync.Summary.EAApp }
        @{ Label = 'Duration';       Value = $sync.Summary.Duration }
    )

    foreach ($row in $rows) {
        if ($null -eq $row.Value) { continue }
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.Text = "{0,-16} : {1}" -f $row.Label, $row.Value
        $tb.FontFamily = 'Consolas'
        $tb.FontSize = 14
        $tb.Margin = '0,2,0,2'
        $tb.Foreground = if ("$($row.Value)" -match '^(ok|success)') { '#66bb6a' }
                         elseif ($row.Label -eq 'Duration') { '#e0e0e0' }
                         else { '#ef5350' }
        $pnlSummary.Children.Add($tb) | Out-Null
    }

    if ($null -ne $sync.EngineExitCode) {
        $tbExit = [System.Windows.Controls.TextBlock]::new()
        $tbExit.Text = "{0,-16} : {1}" -f 'Engine exit code', $sync.EngineExitCode
        $tbExit.FontFamily = 'Consolas'
        $tbExit.FontSize = 14
        $tbExit.Margin = '0,2,0,2'
        $tbExit.Foreground = if ($sync.EngineExitCode -eq 0) { '#66bb6a' } else { '#ef5350' }
        $pnlSummary.Children.Add($tbExit) | Out-Null
    }
}

# Store the completion handler in $sync so background runspaces can invoke it via Dispatcher
$sync.OnRunCompleted = $script:OnRunCompleted
$sync.AutoScrollLog = $script:AutoScrollLog

# --- Driver Store Tab: Element Lookups ---
$btnRefreshDrivers = $sync.Form.FindName('BtnRefreshDrivers')
$dgDrivers = $sync.Form.FindName('DgDrivers')
$txtDriversLoading = $sync.Form.FindName('TxtDriversLoading')
$btnRAPR = $sync.Form.FindName('BtnRAPR')

# --- Driver Store Tab: DriverStoreExplorer Button Visibility ---
if ($sync.RAPRPath -and (Test-Path -LiteralPath $sync.RAPRPath)) {
    $btnRAPR.Visibility = [System.Windows.Visibility]::Visible
}

# --- Driver Store Tab: Refresh Button Click Handler ---
$btnRefreshDrivers.Add_Click({
    # Show loading indicator and disable button during query
    $txtDriversLoading.Visibility = [System.Windows.Visibility]::Visible
    $btnRefreshDrivers.IsEnabled = $false

    # Get current list (if any) to pass as PreviousList
    $previousList = @()
    if ($null -ne $dgDrivers.ItemsSource) {
        $previousList = @($dgDrivers.ItemsSource)
    }

    try {
        # Query the driver store (synchronous for now; background in task 11.2 if needed)
        $result = Get-DriverStoreList -PreviousList $previousList

        if ($result.Success) {
            if ($null -eq $result.Drivers -or $result.Drivers.Count -eq 0) {
                # Empty result — show informational message
                $dgDrivers.ItemsSource = $null
                [System.Windows.MessageBox]::Show(
                    'No third-party drivers found in the driver store.',
                    'Driver Store',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                ) | Out-Null
            }
            else {
                # Success with drivers — update the DataGrid
                $dgDrivers.ItemsSource = $result.Drivers
            }
        }
        elseif ($result.TimedOut) {
            # Timeout — show message, retain previous list
            [System.Windows.MessageBox]::Show(
                'Driver store query timed out after 30 seconds. Previous results retained.',
                'Driver Store - Timeout',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
        else {
            # Failure — show error message, retain previous list
            $errorMsg = if ($result.ErrorMessage) { $result.ErrorMessage } else { 'Unknown error occurred.' }
            [System.Windows.MessageBox]::Show(
                "Driver store query failed: $errorMsg`nPrevious results retained.",
                'Driver Store - Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
    }
    catch {
        # Unexpected exception — show error, retain previous list
        [System.Windows.MessageBox]::Show(
            "Unexpected error querying driver store: $($_.Exception.Message)`nPrevious results retained.",
            'Driver Store - Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    finally {
        # Hide loading indicator and re-enable button
        $txtDriversLoading.Visibility = [System.Windows.Visibility]::Collapsed
        $btnRefreshDrivers.IsEnabled = $true
    }
})

# --- Driver Store Tab: Launch DriverStoreExplorer Button Click Handler ---
$btnRAPR.Add_Click({
    if ($sync.RAPRPath -and (Test-Path -LiteralPath $sync.RAPRPath)) {
        Start-Process $sync.RAPRPath
    }
    else {
        [System.Windows.MessageBox]::Show(
            'DriverStoreExplorer (RAPR) not found at the configured path.',
            'Driver Store Explorer',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
    }
})

# --- SDIO Button Click Handler ---
$btnSDIO.Add_Click({
    if (-not $sync.SDIOPath -or -not (Test-Path -LiteralPath $sync.SDIOPath)) {
        $pathMsg = if ($sync.SDIOPath) { $sync.SDIOPath } else { '(not configured)' }
        [System.Windows.MessageBox]::Show(
            "SDIO not found at path: $pathMsg`nPlease configure the SDIOPath setting.",
            'SDIO Not Found',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }
    try {
        Start-SDIOGui -SDIOPath $sync.SDIOPath
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Error launching SDIO: $($_.Exception.Message)",
            'SDIO Launch Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# --- NVCleanstall Button Click Handler ---
$btnNVClean.Add_Click({
    if (-not $sync.NVCleanPath -or -not (Test-Path -LiteralPath $sync.NVCleanPath)) {
        [System.Windows.MessageBox]::Show(
            "NVCleanstall not found at configured path.`nDownload from: https://www.techpowerup.com/download/techpowerup-nvcleanstall/",
            'NVCleanstall Not Found',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }
    try {
        Start-NVCleanstall -NVCleanstallPath $sync.NVCleanPath
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Error launching NVCleanstall: $($_.Exception.Message)",
            'NVCleanstall Launch Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# --- Pin Editor Tab: Element Lookups ---
$lstPins      = $sync.Form.FindName('LstPins')
$txtNewPinId  = $sync.Form.FindName('TxtNewPinId')
$cboManager   = $sync.Form.FindName('CboManager')
$btnAddPin    = $sync.Form.FindName('BtnAddPin')
$btnRemovePin = $sync.Form.FindName('BtnRemovePin')
$btnSavePins  = $sync.Form.FindName('BtnSavePins')
$txtPinError  = $sync.Form.FindName('TxtPinError')

# --- Pin Editor Tab: Populate ListView with ObservableCollection ---
$sync.PinCollection = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()

# Load existing pins from $sync.Pins into the ObservableCollection
foreach ($pin in $sync.Pins) {
    $sync.PinCollection.Add([PSCustomObject]@{ Id = $pin.Id; Manager = $pin.Manager })
}

$lstPins.ItemsSource = $sync.PinCollection

# --- Pin Editor Tab: Clear Validation on Text Change ---
$txtNewPinId.Add_TextChanged({
    $txtPinError.Text = ''
})

# --- Pin Editor Tab: Add Button Click Handler ---
$btnAddPin.Add_Click({
    $newId = $txtNewPinId.Text.Trim()
    $selectedManager = $cboManager.SelectedItem.Content

    # Validate via Test-PinId using current collection as existing pins
    $existingPins = @($sync.PinCollection | ForEach-Object { [PSCustomObject]@{ Id = $_.Id; Manager = $_.Manager } })
    $validation = Test-PinId -Id $newId -Manager $selectedManager -ExistingPins $existingPins

    if (-not $validation.Valid) {
        $txtPinError.Text = $validation.Reason
        return
    }

    # Validation passed — add to collection and clear input
    $sync.PinCollection.Add([PSCustomObject]@{ Id = $newId; Manager = $selectedManager })
    $txtNewPinId.Text = ''
    $txtPinError.Text = ''
})

# --- Pin Editor Tab: Remove Button Click Handler ---
$btnRemovePin.Add_Click({
    $selectedItem = $lstPins.SelectedItem
    if ($null -ne $selectedItem) {
        $sync.PinCollection.Remove($selectedItem) | Out-Null
        $txtPinError.Text = ''
    }
})

# --- Pin Editor Tab: Save Button Click Handler ---
$btnSavePins.Add_Click({
    # Build pin array from the ObservableCollection
    $pinsToSave = @($sync.PinCollection | ForEach-Object {
        [PSCustomObject]@{ Id = $_.Id; Manager = $_.Manager }
    })

    try {
        Set-PinListInBat -BatFilePath $sync.EnginePath -Pins $pinsToSave
        $txtPinError.Text = ''
        # Update $sync.Pins to reflect the saved state
        $sync.Pins = $pinsToSave
    }
    catch {
        # Write failure — show error, preserve edits in UI
        $txtPinError.Text = "Save failed: $($_.Exception.Message)"
    }
})

# --- Initialize RunspacePool (before ShowDialog) ---
Initialize-RunspacePool

# --- Elapsed Time Timer ---
$script:ElapsedTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:ElapsedTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:ElapsedTimer.Add_Tick({
    if ($sync.IsRunning -and $null -ne $sync.RunStartTime) {
        $elapsed = [DateTime]::Now - $sync.RunStartTime
        $txtElapsed.Text = "Elapsed: {0:hh\:mm\:ss}" -f $elapsed

        # Stale output detection (120 seconds without output)
        if ($null -ne $sync.LastOutputTime) {
            $sinceOutput = ([DateTime]::Now - $sync.LastOutputTime).TotalSeconds
            if ($sinceOutput -ge 120) {
                $txtWaiting.Visibility = [System.Windows.Visibility]::Visible
            }
            else {
                $txtWaiting.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }

        # Update category status labels from $sync.CategoryStatus
        $statusWindowsUpdate.Text = $sync.CategoryStatus['WindowsUpdate']
        $statusStore.Text = $sync.CategoryStatus['Store']
        $statusApps.Text = $sync.CategoryStatus['Apps']
        $statusDrivers.Text = $sync.CategoryStatus['Drivers']

        # Auto-scroll log and update log text from buffer
        $logText = $sync.LogLines -join "`r`n"
        if ($txtLog.Text -ne $logText) {
            $txtLog.Text = $logText
            & $script:AutoScrollLog
        }
    }
    else {
        $txtElapsed.Text = ""
    }
})
$script:ElapsedTimer.Start()

# --- Window Closing Handler ---
$sync.Form.Add_Closing({
    $script:ElapsedTimer.Stop()
    Close-RunspacePool
})

# --- ShowDialog ---
$sync.Form.ShowDialog() | Out-Null
