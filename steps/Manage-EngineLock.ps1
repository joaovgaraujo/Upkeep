# The owner is the calling cmd.exe, not this short-lived PowerShell helper.
# Serialize inspection + replacement; never expire a lock by elapsed time.
[CmdletBinding()]
param([ValidateSet('Acquire', 'Release')][string]$Action = 'Acquire',
      [string]$LockDirectory = (Join-Path $env:TEMP 'SystemUpdate_Topgrade.lock'))

function Invoke-EngineLock {
    param([string]$Action, [string]$LockDirectory, $Caller)
    $ownerFile = Join-Path $LockDirectory 'owner.json'
    $identity = [pscustomobject]@{
        ProcessId = [int]$Caller.ProcessId
        Created = $Caller.CreationDate.ToUniversalTime().Ticks.ToString()
    }
    $saved = $null
    if (Test-Path -LiteralPath $ownerFile) {
        try { $saved = Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json }
        catch { } # Interrupted write: use the live engine scan below.
    }
    if ($Action -eq 'Release') {
        if ($saved -and $saved.ProcessId -eq $identity.ProcessId -and $saved.Created -eq $identity.Created) {
            Remove-Item -LiteralPath $ownerFile -Force -ErrorAction Stop
            # No recursive deletion: retain unexpected contents for inspection.
            if (@(Get-ChildItem -LiteralPath $LockDirectory -Force).Count -eq 0) {
                Remove-Item -LiteralPath $LockDirectory -Force -ErrorAction Stop
            }
        }
        return 0
    }
    if ($saved -and $saved.ProcessId -and $saved.Created) {
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$saved.ProcessId)" -ErrorAction Stop
        if ($owner -and $owner.CreationDate.ToUniversalTime().Ticks.ToString() -eq $saved.Created) {
            Write-Host "[guard] An update is still running (PID $($saved.ProcessId)). Wait for it to finish or stop it in its Upkeep window."
            return 2
        }
    }
    # Also protects runs from older versions, which never recorded an owner.
    # Scan even when the old folder is absent (another account has another TEMP).
    $engines = @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction Stop |
        Where-Object { $_.ProcessId -ne $Caller.ProcessId -and $_.CommandLine -match '(?i)SystemUpdate_Topgrade\.bat' })
    if ($engines.Count -gt 0) {
        Write-Host "[guard] Another update engine is running (PID $($engines[0].ProcessId)). Wait for it to finish or stop it in its Upkeep window."
        return 2
    }
    if (Test-Path -LiteralPath $LockDirectory) {
        Write-Host '[guard] Recovered an abandoned update lock. Starting normally.'
    } else {
        New-Item -ItemType Directory -Path $LockDirectory -ErrorAction Stop | Out-Null
    }
    $identity | ConvertTo-Json | Set-Content -LiteralPath $ownerFile -Encoding UTF8 -ErrorAction Stop
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $mutex = $null
    $held = $false
    $code = 1
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\Upkeep.EngineLock.Management')
        try { $held = $mutex.WaitOne(30000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out checking update ownership. Try again shortly.' }
        $helper = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
        $caller = Get-CimInstance Win32_Process -Filter "ProcessId = $($helper.ParentProcessId)"
        if (-not $caller -or $caller.Name -ne 'cmd.exe') { throw 'The lock helper must be called by the batch engine.' }
        $code = Invoke-EngineLock -Action $Action -LockDirectory $LockDirectory -Caller $caller
    } catch {
        Write-Host "[guard] Could not $($Action.ToLower()) the update lock: $($_.Exception.Message)"
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
    exit $code
}
