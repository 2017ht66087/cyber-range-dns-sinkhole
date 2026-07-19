<#
.SYNOPSIS
    Reset or fully remove the range.
    -Mode Reset  : revert every VM to 'scenario-armed' (fast, keeps VMs).
    -Mode Clean  : revert every VM to 'baseline-clean'.
    -Mode Destroy: power off + delete all clones (VMnets left intact).
.NOTES
    Destroy is irreversible for the clones. Export evidence to MGMT-BKP first.
#>
[CmdletBinding()]
param(
    [ValidateSet('Reset','Clean','Destroy')][string]$Mode = 'Reset',
    [switch]$Confirm,
    [switch]$DryRun
)
. "$PSScriptRoot\_common.ps1"

$vmrun = Find-VMwareTool -Exe 'vmrun.exe'
if (-not $vmrun) { Write-Err2 "vmrun.exe not found."; exit 1 }
$inv  = Get-RangeInventory
$base = $inv.Settings.BaseVMPath

function Invoke-VmRun { param([string[]]$CmdArgs)
    if ($DryRun) { Write-Host "    DRYRUN> vmrun $($CmdArgs -join ' ')" -ForegroundColor DarkGray; return }
    & $vmrun @CmdArgs 2>$null }

if ($Mode -eq 'Destroy' -and -not $Confirm -and -not $DryRun) {
    Write-Err2 "Destroy is irreversible. Re-run with -Confirm to proceed."; exit 1
}

$snap = switch ($Mode) { 'Reset' {$inv.Settings.SnapshotArmed} 'Clean' {$inv.Settings.SnapshotClean} default {$null} }

# Shut down in reverse tier order first.
foreach ($tier in ($inv.VMs.BootTier | Sort-Object -Unique -Descending)) {
    foreach ($vm in ($inv.VMs | Where-Object BootTier -eq $tier)) {
        $vmx = Join-Path $base "$($vm.Name)\$($vm.Name).vmx"
        if (-not (Test-Path $vmx) -and -not $DryRun) { continue }
        Write-Step "$Mode : $($vm.Name)"
        Invoke-VmRun @('-T','ws','stop',$vmx,'hard')
        if ($snap)               { Invoke-VmRun @('-T','ws','revertToSnapshot',$vmx,$snap) }
        if ($Mode -eq 'Destroy') { Invoke-VmRun @('-T','ws','deleteVM',$vmx) }
    }
}
Write-Ok "$Mode complete."
