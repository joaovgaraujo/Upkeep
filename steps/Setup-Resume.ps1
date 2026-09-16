# Shared, opt-in restart/resume support. Dot-source; never reboots on import.
function Get-SetupBootId {
    (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Invoke-SetupRestart {
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Restart was not accepted. The saved task will wait for your manual restart.' }
}

function Get-RebootApps {
    param([object[]]$Results)
    @($Results | Where-Object { $_.Status -eq 'Deferred' -and $_.RebootRequired -eq $true } | ForEach-Object { $_.Slug } | Select-Object -Unique)
}

function Get-SetupRestartChoice {
    param([string]$Details)
    Add-Type -AssemblyName System.Windows.Forms
    $pt = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pt'
    $text = if ($pt) {
        "O Windows precisa reiniciar para concluir a configuração.`n`n$Details`n`nSalve seu trabalho antes de continuar.`nSim: reiniciar agora e continuar após entrar no Windows.`nNão: continuar automaticamente quando você reiniciar e entrar depois.`nCancelar: não agendar nem reiniciar."
    } else {
        "Windows needs a restart to finish setup.`n`n$Details`n`nSave your work before continuing.`nYes: restart now and continue after Windows sign-in.`nNo: continue automatically after you restart and sign in later.`nCancel: do not schedule or restart."
    }
    [string][Windows.Forms.MessageBox]::Show($text, 'Upkeep', 'YesNoCancel', 'Question', 'Button3')
}

function Save-SetupResumeState {
    param([string]$Path, $State)
    $temp = $Path + '.tmp'
    ConvertTo-Json -InputObject $State -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Request-SetupResume {
    param([string]$Root, [string[]]$Apps = @(), [string[]]$Tweaks = @(),
          [string]$Catalog, [switch]$PreferChoco, [switch]$RestartRequired)
    if (-not $Apps.Count -and -not $Tweaks.Count -and -not $RestartRequired) { return }
    $details = "Apps: $($Apps -join ', ')`nWindows tweaks: $($Tweaks -join ', ')"
    if (-not $Apps.Count -and -not $Tweaks.Count) { $details = 'Finish Windows changes; already installed apps will not be installed again.' }
    $choice = Get-SetupRestartChoice $details
    if ($choice -notin @('Yes','No')) { Write-Output '[resume] Not scheduled. You can retry from Upkeep later.'; return }
    if (Get-ScheduledTask -TaskName 'Upkeep-Resume-*' -ErrorAction SilentlyContinue) { throw 'A continuation is already scheduled. Use Manage restart continuation before scheduling another.' }

    # A task running elevated must not execute mutable files from Downloads/USB.
    # Snapshot the selected payload into an admin/SYSTEM-writable directory.
    $base = Join-Path $env:ProgramData 'Upkeep-Resume'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    if ((Get-Item -LiteralPath $base).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Resume folder must not be a link.' }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $base -AclObject $acl -ErrorAction Stop
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $base $id
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'Install-Apps.ps1'), (Join-Path $Root 'Setup-NewPC.ps1') -Destination $dir
    Copy-Item -LiteralPath (Join-Path $Root 'steps') -Destination $dir -Recurse
    Copy-Item -LiteralPath (Join-Path $Root 'presets') -Destination $dir -Recurse
    if (-not $Catalog) { $Catalog = Join-Path $Root 'apps.json' }
    Copy-Item -LiteralPath $Catalog -Destination (Join-Path $dir 'apps.json')
    if (Test-Path -LiteralPath (Join-Path $Root 'settings.json')) { Copy-Item -LiteralPath (Join-Path $Root 'settings.json') -Destination $dir }
    $task = 'Upkeep-Resume-' + $id
    $statePath = Join-Path $dir 'resume.json'
    $state = [pscustomobject]@{ Version=1; Task=$task; BootId=(Get-SetupBootId); Status='WaitingForRestart'; Apps=@($Apps); Tweaks=@($Tweaks); PreferChoco=[bool]$PreferChoco; Detail='Waiting for a restart and sign-in.' }
    Save-SetupResumeState $statePath $state
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'steps\Resume-Setup.ps1') + '" -StatePath "' + $statePath + '"')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # No restart if saving the payload or registering the task fails.
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    Write-Output "[resume] Scheduled after your next restart/sign-in. State: $statePath"
    Write-Output "[resume] Cancel in Upkeep with Manage restart continuation, or Task Scheduler: $task"
    if ($choice -eq 'Yes') {
        # /t 0 without /f: never forcibly close applications with unsaved work.
        Invoke-SetupRestart
    }
}
