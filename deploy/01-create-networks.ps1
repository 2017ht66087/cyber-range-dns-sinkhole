<#
.SYNOPSIS
    Creates the six isolated VMnets (host-only) defined in inventory.psd1 using
    VMware's vnetlib64.exe. DHCP is disabled on every vnet (SEC-GW serves DHCP).
    Host virtual adapters are added ONLY for MGMT/SOC; other zones stay blind.
.NOTES
    Run in an ELEVATED PowerShell. vnetlib64 syntax can vary by Workstation
    version; use -DryRun first to review the exact commands.
#>
[CmdletBinding()]
param([switch]$DryRun)
. "$PSScriptRoot\_common.ps1"

$vnetlib = Find-Vnetlib
if (-not $vnetlib) { Write-Err2 "vnetlib(64).exe not found. Install VMware Workstation."; exit 1 }
if (-not (Test-IsAdmin) -and -not $DryRun) { Write-Err2 "Must run elevated. Re-launch PowerShell as Administrator."; exit 1 }

$inv = Get-RangeInventory

function Invoke-Vnet {
    param([string[]]$CmdArgs)
    $display = "`"$vnetlib`" $($CmdArgs -join ' ')"
    if ($DryRun) { Write-Host "    DRYRUN> $display" -ForegroundColor DarkGray; return }
    & $vnetlib @CmdArgs | Out-Null
}

foreach ($n in $inv.Networks) {
    Write-Step "Configuring $($n.Name) ($($n.Zone)) $($n.Subnet)/$($n.Mask)"
    Invoke-Vnet @('--','add','adapter',$n.Name)
    Invoke-Vnet @('--','set','vnet',$n.Name,'addr',$n.Subnet)
    Invoke-Vnet @('--','set','vnet',$n.Name,'mask',$n.Mask)
    # Disable the built-in DHCP; SEC-GW (pfSense) is the only DHCP authority.
    Invoke-Vnet @('--','remove','dhcp',$n.Name)
    if ($n.HostAdapter) {
        Invoke-Vnet @('--','update','adapter',$n.Name)
        Write-Ok "$($n.Name): host adapter enabled (admin/analyst access)."
    } else {
        Invoke-Vnet @('--','remove','adapter',$n.Name)
        Write-Ok "$($n.Name): blind segment (no host adapter)."
    }
}

if (-not $DryRun) {
    Write-Step "Applying network changes (restart VMware NAT/DHCP services)"
    Invoke-Vnet @('--','stop','dhcp'); Invoke-Vnet @('--','stop','nat')
    Invoke-Vnet @('--','start','dhcp'); Invoke-Vnet @('--','start','nat')
}
Write-Ok "Network stage complete. Next: 02-deploy-vms.ps1"
