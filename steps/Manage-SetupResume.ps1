$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup-Resume.ps1')
$tasks = @(Get-ScheduledTask -TaskName 'Upkeep-Resume-*' -ErrorAction SilentlyContinue)
if (-not $tasks.Count) { Write-Host 'No restart continuation is scheduled.'; exit 0 }
Write-Host 'The following approved setup jobs will continue after a restart and sign-in:'
$tasks | Select-Object TaskName, State | Format-Table
Write-Host 'R = restart now and continue (save your work first)'
Write-Host 'C = cancel all scheduled setup continuations'
Write-Host 'Enter = leave them scheduled; do not restart now'
$choice = Read-Host 'Choose'
if ($choice -eq 'R') {
    Invoke-SetupRestart
} elseif ($choice -eq 'C') {
    foreach ($task in $tasks) {
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
        if ($task.TaskName -match '^Upkeep-Resume-([a-f0-9]{32})$') {
            $statePath = Join-Path $env:ProgramData ('Upkeep-Resume\' + $Matches[1] + '\resume.json')
            if (Test-Path -LiteralPath $statePath) {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $state.Status = 'Cancelled'
                $state.Detail = 'User cancelled the scheduled continuation; no restart requested.'
                Save-SetupResumeState $statePath $state
            }
        }
        Write-Host "Cancelled $($task.TaskName)"
    }
}
