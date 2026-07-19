<#
.SYNOPSIS
    Preflight for the cyber range. Verifies VMware Workstation, host resources,
    templates, and inventory before any deployment. Safe/read-only.
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\_common.ps1"

$pass = $true
Write-Step "Cyber Range preflight starting..."

# --- VMware Workstation tooling ---
$vmrun   = Find-VMwareTool -Exe 'vmrun.exe'
$vnetlib = Find-Vnetlib
if ($vmrun)   { Write-Ok "vmrun found:   $vmrun" }   else { Write-Err2 "vmrun.exe NOT found - VMware Workstation is not installed."; $pass=$false }
if ($vnetlib) { Write-Ok "vnetlib found: $vnetlib" } else { Write-Err2 "vnetlib(64).exe NOT found - cannot create VMnets."; $pass=$false }

# --- Admin rights (needed to create VMnets) ---
if (Test-IsAdmin) { Write-Ok "Running elevated (Administrator)." }
else { Write-Warn2 "Not elevated. Network creation (01-create-networks.ps1) requires an elevated shell." }

# --- Host resources ---
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$free = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace/1GB,1)
Write-Host ("    RAM={0}GB  vCPU={1}  FreeC:={2}GB" -f $ram,$cpu,$free)
if ($ram  -lt 24) { Write-Warn2 "RAM < 24GB: reduce endpoints or memory in inventory.psd1." }
if ($free -lt 200){ Write-Warn2 "Free disk < 200GB: use linked clones and thin disks." }

# --- Inventory sanity ---
try {
    $inv = Get-RangeInventory
    Write-Ok ("Inventory OK: {0} networks, {1} VMs." -f $inv.Networks.Count, $inv.VMs.Count)
} catch { Write-Err2 "Inventory failed to load: $($_.Exception.Message)"; $pass=$false; $inv=$null }

# --- Templates present? ---
if ($inv) {
    $tpl = $inv.Settings.TemplatePath
    $needed = $inv.VMs.Template | Sort-Object -Unique
    Write-Step "Checking base templates in $tpl"
    foreach ($t in $needed) {
        $vmx = Join-Path $tpl "$t\$t.vmx"
        if (Test-Path $vmx) { Write-Ok "template present: $t" }
        else { Write-Warn2 "MISSING template: $t  (expected $vmx)"; }
    }
}

Write-Host ""
if ($pass) { Write-Ok  "PREFLIGHT PASSED - core tooling present. Resolve any warnings above, then run 01-create-networks.ps1." }
else       { Write-Err2 "PREFLIGHT FAILED - install VMware Workstation and re-run. See README.md."; }
exit ([int](-not $pass))
