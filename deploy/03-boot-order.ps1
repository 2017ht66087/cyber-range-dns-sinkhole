<#
.SYNOPSIS
    Powers the range on/off in dependency order (BootTier).
    Start = ascending tier; Stop = descending tier. Optionally revert first.
.EXAMPLE
    .\03-boot-order.ps1 -Action Start -RevertTo scenario-armed
    .\03-boot-order.ps1 -Action Stop
#>
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop')][string]$Action = 'Start',
    [string]$RevertTo,
    [int]$TierDelaySec = 45,
    [switch]$DryRun
)
. "$PSScriptRoot\_common.ps1"

$vmrun = Find-VMwareTool -Exe 'vmrun.exe'
if (-not $vmrun) { Write-Err2 "vmrun.exe not found. Install VMware Workstation."; exit 1 }

$inv  = Get-RangeInventory
$base = $inv.Settings.BaseVMPath
$tiers = $inv.VMs.BootTier | Sort-Object -Unique
if ($Action -eq 'Stop') { $tiers = $tiers | Sort-Object -Descending }

function Invoke-VmRun { param([string[]]$CmdArgs)
    if ($DryRun) { Write-Host "    DRYRUN> vmrun $($CmdArgs -join ' ')" -ForegroundColor DarkGray; return }
    & $vmrun @CmdArgs }

foreach ($tier in $tiers) {
    $vmsInTier = $inv.VMs | Where-Object { $_.BootTier -eq $tier }
    Write-Step "$Action tier $tier : $($vmsInTier.Name -join ', ')"
    foreach ($vm in $vmsInTier) {
        $vmx = Join-Path $base "$($vm.Name)\$($vm.Name).vmx"
        if (-not (Test-Path $vmx) -and -not $DryRun) { Write-Warn2 "$($vm.Name) not deployed. Skipping."; continue }
        if ($Action -eq 'Start') {
            if ($RevertTo) { Invoke-VmRun @('-T','ws','revertToSnapshot',$vmx,$RevertTo) }
            Invoke-VmRun @('-T','ws','start',$vmx,'nogui')
        } else {
            Invoke-VmRun @('-T','ws','stop',$vmx,'soft')
        }
    }
    if ($Action -eq 'Start' -and $tier -ne ($tiers | Select-Object -Last 1)) {
        Write-Host "    ...waiting $TierDelaySec s for tier $tier to settle" -ForegroundColor DarkGray
        if (-not $DryRun) { Start-Sleep -Seconds $TierDelaySec }
    }
}
Write-Ok "$Action complete."
