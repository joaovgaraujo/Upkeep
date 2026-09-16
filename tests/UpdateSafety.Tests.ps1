BeforeAll {
    $safetyScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'steps\Set-UpdateSafety.ps1'
    $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Invoke-FakeSafety {
        param([int]$WingetListCode=0, [int]$WingetPinCode=0, [int]$ChocoPinCode=0, [bool]$ChocoInstalled=$true)
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $case -ItemType Directory | Out-Null
        Copy-Item $safetyScript $case
        # Functions take precedence over executables. No package manager is run.
        $wrapper = @'
function winget {
    Add-Content "$PSScriptRoot\calls.txt" ("winget " + ($args -join ' '))
    if ($args[0] -eq 'list') { $global:LASTEXITCODE = WINGET_LIST_CODE }
    else { $global:LASTEXITCODE = WINGET_PIN_CODE }
}
function choco {
    Add-Content "$PSScriptRoot\calls.txt" ("choco " + ($args -join ' '))
    if ($args[0] -eq 'list') { CHOCO_INSTALLED; $global:LASTEXITCODE = 0 }
    else { $global:LASTEXITCODE = CHOCO_PIN_CODE }
}
try { & "$PSScriptRoot\Set-UpdateSafety.ps1"; exit 0 } catch { Write-Host $_; exit 1 }
'@
        $listed = if ($ChocoInstalled) { "'ea-app|1.0'" } else { '$null' }
        $wrapper = $wrapper.Replace('WINGET_LIST_CODE', "$WingetListCode").Replace('WINGET_PIN_CODE', "$WingetPinCode").Replace('CHOCO_PIN_CODE', "$ChocoPinCode").Replace('CHOCO_INSTALLED', $listed)
        Set-Content "$case\wrapper.ps1" $wrapper
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "$case\wrapper.ps1" | Out-Null
        [pscustomobject]@{ Code=$LASTEXITCODE; Calls=(Get-Content "$case\calls.txt" -Raw) }
    }
}
Describe 'EA reboot guard with fake package managers' {
    It 'blocks EA in both managers, with a non-overridable winget pin' {
        $run = Invoke-FakeSafety
        $run.Code | Should -Be 0
        $run.Calls | Should -Match 'winget pin add.*ElectronicArts.EADesktop.*--blocking.*--force'
        $run.Calls | Should -Match 'choco pin add --name=ea-app'
    }
    It 'does not fail on machines without EA' {
        $run = Invoke-FakeSafety -WingetListCode -1978335212 -ChocoInstalled $false
        $run.Code | Should -Be 0
        $run.Calls | Should -Not -Match 'pin add'
    }
    It 'stops before updates when winget cannot enforce the guard' {
        (Invoke-FakeSafety -WingetPinCode 1).Code | Should -Be 1
    }
    It 'stops before updates when Chocolatey cannot enforce the guard' {
        (Invoke-FakeSafety -ChocoPinCode 1).Code | Should -Be 1
    }
    It 'does not treat a failed inventory as EA being absent' {
        (Invoke-FakeSafety -WingetListCode 1).Code | Should -Be 1
    }
}
