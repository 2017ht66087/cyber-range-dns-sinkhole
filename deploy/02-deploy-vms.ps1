<#
.SYNOPSIS
    Clones every range VM from its base template (linked clones), attaches the
    correct VMnets, sets CPU/RAM, and takes the 'baseline-clean' snapshot.
.NOTES
    Requires base templates present under Settings.TemplatePath (see preflight).
    Use -DryRun to preview without touching disk.
#>
[CmdletBinding()]
param([switch]$DryRun,[switch]$Linked)
. "$PSScriptRoot\_common.ps1"

$vmrun = Find-VMwareTool -Exe 'vmrun.exe'
if (-not $vmrun) { Write-Err2 "vmrun.exe not found. Install VMware Workstation."; exit 1 }

$inv  = Get-RangeInventory
$base = $inv.Settings.BaseVMPath
$tpl  = $inv.Settings.TemplatePath
if (-not $DryRun -and -not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

function Invoke-VmRun {
    param([string[]]$CmdArgs)
    if ($DryRun) { Write-Host "    DRYRUN> vmrun $($CmdArgs -join ' ')" -ForegroundColor DarkGray; return }
    & $vmrun @CmdArgs
}

foreach ($vm in ($inv.VMs | Sort-Object BootTier)) {
    $srcVmx  = Join-Path $tpl  "$($vm.Template)\$($vm.Template).vmx"
    $destDir = Join-Path $base $vm.Name
    $destVmx = Join-Path $destDir "$($vm.Name).vmx"

    Write-Step "Deploying $($vm.Name) [$($vm.Role)] from $($vm.Template)"
    if (-not (Test-Path $srcVmx) -and -not $DryRun) { Write-Warn2 "Template missing ($srcVmx). Skipping $($vm.Name)."; continue }
    if (Test-Path $destVmx) { Write-Warn2 "$($vm.Name) already deployed. Skipping."; continue }

    $mode = if ($Linked) { 'linked' } else { 'full' }
    Invoke-VmRun @('-T','ws','clone',$srcVmx,$destVmx,$mode,"-cloneName=$($vm.Name)")

    if (-not $DryRun) {
        Set-VmxNics       -VmxPath $destVmx -Vnets $vm.Nics
        Set-VmxResources  -VmxPath $destVmx -CPU $vm.CPU -MemMB $vm.MemMB
    } else {
        Write-Host ("    DRYRUN> attach NICs {0}; set {1} vCPU / {2} MB" -f ($vm.Nics -join ','),$vm.CPU,$vm.MemMB) -ForegroundColor DarkGray
    }

    Invoke-VmRun @('-T','ws','snapshot',$destVmx,$inv.Settings.SnapshotClean)
    Write-Ok "$($vm.Name) deployed, NICs=$($vm.Nics -join ','), snapshot='$($inv.Settings.SnapshotClean)'"
}

Write-Ok "Deploy stage complete. Configure guests via Ansible, then snapshot 'scenario-armed'. Boot with 03-boot-order.ps1"
