# =====================================================================
# _common.ps1 - shared helpers for the cyber-range deployment kit
# Dot-source this from the other scripts:  . "$PSScriptRoot\_common.ps1"
# =====================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RangeInventory {
    $invPath = Join-Path $PSScriptRoot '..\config\inventory.psd1'
    if (-not (Test-Path $invPath)) { throw "Inventory not found at $invPath" }
    $inv = Import-PowerShellDataFile -Path $invPath
    # Enabled=$false rows stay in the file as the full design, but deploy/boot skip them.
    if ($inv.ContainsKey('VMs')) {
        $inv.VMs = @($inv.VMs | Where-Object {
            -not $_.ContainsKey('Enabled') -or $_.Enabled
        })
    }
    return $inv
}

function Find-VMwareTool {
    param([Parameter(Mandatory)][string]$Exe)   # e.g. 'vmrun.exe' or 'vnetlib64.exe'
    $roots = @(
        "C:\Program Files (x86)\VMware\VMware Workstation",
        "C:\Program Files\VMware\VMware Workstation",
        "C:\Program Files (x86)\VMware\VMware Player",
        "C:\Program Files\VMware\VMware Player",
        "C:\Program Files (x86)\VMware\VMware VIX"
    )
    foreach ($r in $roots) { $p = Join-Path $r $Exe; if (Test-Path $p) { return $p } }
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# The network CLI is vnetlib64.exe on some builds and vnetlib.exe on others.
function Find-Vnetlib {
    foreach ($name in 'vnetlib64.exe','vnetlib.exe') {
        $p = Find-VMwareTool -Exe $name
        if ($p) { return $p }
    }
    return $null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn2{ param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err2 { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }

# Rewrite/insert ethernetN.* lines in a .vmx to attach custom VMnets.
function Set-VmxNics {
    param(
        [Parameter(Mandatory)][string]$VmxPath,
        [Parameter(Mandatory)][string[]]$Vnets
    )
    if (-not (Test-Path $VmxPath)) { throw "vmx not found: $VmxPath" }
    $lines = Get-Content $VmxPath | Where-Object { $_ -notmatch '^ethernet\d+\.' }
    for ($i = 0; $i -lt $Vnets.Count; $i++) {
        $lines += "ethernet$i.present = `"TRUE`""
        $lines += "ethernet$i.connectionType = `"custom`""
        $lines += "ethernet$i.vnet = `"$($Vnets[$i])`""
        $lines += "ethernet$i.virtualDev = `"e1000`""
        $lines += "ethernet$i.addressType = `"generated`""
    }
    Set-Content -Path $VmxPath -Value $lines -Encoding ASCII
}

# Rewrite numCPUs / memSize in a .vmx.
function Set-VmxResources {
    param([string]$VmxPath, [int]$CPU, [int]$MemMB)
    $lines = Get-Content $VmxPath | Where-Object { $_ -notmatch '^(numvcpus|memsize)\s*=' }
    $lines += "numvcpus = `"$CPU`""
    $lines += "memsize = `"$MemMB`""
    Set-Content -Path $VmxPath -Value $lines -Encoding ASCII
}
