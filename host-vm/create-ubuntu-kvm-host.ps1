<#
.SYNOPSIS
    Create (and optionally boot) an Ubuntu 24.04 KVM-host VM in VMware
    Workstation, with nested virtualization enabled, booting the local Ubuntu
    ISO + the autoinstall seed ISO. Inside this VM you run the Ubuntu range kit.
.DESCRIPTION
    Windows lacks a from-scratch VM creator in vmrun, so this writes a .vmx and
    a blank vmdk directly (via vmware-vdiskmanager), then boots with vmrun.
    Because this box currently has limited free RAM, power-on is gated: use
    -Start only after freeing memory. Default sizing targets a TRIMMED range.
.EXAMPLE
    .\create-ubuntu-kvm-host.ps1                              # create only
    .\create-ubuntu-kvm-host.ps1 -MemMB 12288 -Cpu 6 -Start   # create + boot
#>
[CmdletBinding()]
param(
    [string]$IsoPath  = "$env:USERPROFILE\Downloads\ubuntu-24.04.4-live-server-amd64.iso",
    [string]$SeedIso,   # defaults to <script dir>\seed.iso (set in body)
    [string]$VmDir    = "C:\CyberRange\host-vm\range-host",
    [int]$MemMB       = 8192,
    [int]$Cpu         = 6,
    [int]$DiskGB      = 200,
    [switch]$Start,
    [switch]$NoNested,  # omit vhv.enable so the VM boots without nested VT-x
                        # (required on hosts with VBS/Hyper-V owning VT-x;
                        #  KVM inside then runs via slow QEMU TCG emulation)
    [switch]$Installed  # OS already installed: boot from disk, detach installer
)                       # media (use after autoinstall finished)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty during param binding, so resolve seed path here.
if (-not $SeedIso) { $SeedIso = Join-Path $PSScriptRoot 'seed.iso' }

function Find-VMwareExe([string]$Exe) {
    foreach ($r in "C:\Program Files\VMware\VMware Workstation","C:\Program Files (x86)\VMware\VMware Workstation") {
        $p = Join-Path $r $Exe; if (Test-Path $p) { return $p }
    }
    (Get-Command $Exe -ErrorAction SilentlyContinue).Source
}
$vmrun   = Find-VMwareExe 'vmrun.exe'
$vdiskmgr= Find-VMwareExe 'vmware-vdiskmanager.exe'
if (-not $vmrun)    { throw "vmrun.exe not found (VMware Workstation)." }
if (-not $vdiskmgr) { throw "vmware-vdiskmanager.exe not found." }
if (-not (Test-Path $IsoPath)) { throw "Ubuntu ISO not found: $IsoPath" }
if (-not (Test-Path $SeedIso)) { throw "Seed ISO not found: $SeedIso. Run build-seed-iso.ps1 first." }

New-Item -ItemType Directory -Path $VmDir -Force | Out-Null
$vmx  = Join-Path $VmDir 'range-host.vmx'
$vmdk = Join-Path $VmDir 'range-host.vmdk'

# --- blank disk ---
if (-not (Test-Path $vmdk)) {
    Write-Host "[*] Creating ${DiskGB}GB virtual disk..." -ForegroundColor Cyan
    & $vdiskmgr -c -s "${DiskGB}GB" -a lsilogic -t 1 $vmdk | Out-Null
}

# --- .vmx (nested virt via vhv.enable unless -NoNested; two CD-ROMs: installer + seed) ---
if ($NoNested) {
    $vhvLine = '# vhv.enable omitted (-NoNested): KVM inside runs via QEMU TCG emulation'
    Write-Host "[*] Writing $vmx (NESTED DISABLED - KVM will be emulated/slow)..." -ForegroundColor Yellow
} else {
    $vhvLine = 'vhv.enable = "TRUE"'
    Write-Host "[*] Writing $vmx (nested virt enabled)..." -ForegroundColor Cyan
}

if ($Installed) {
    # OS already installed: no installer media, boot from the virtual disk.
    $isoLines  = 'sata0.present = "TRUE"'
    $bootOrder = 'hdd,cdrom'
} else {
    $isoLines  = @"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$($IsoPath -replace '\\','\\')"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$($SeedIso -replace '\\','\\')"
"@
    $bootOrder = 'cdrom,hdd'
}
@"
.encoding = "windows-1252"
config.version = "8"
virtualHW.version = "21"
displayName = "range-host (Ubuntu KVM host)"
guestOS = "ubuntu-64"
firmware = "efi"
memsize = "$MemMB"
numvcpus = "$Cpu"
msg.autoAnswer = "TRUE"
$vhvLine
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "range-host.vmdk"
$isoLines
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
ethernet0.addressType = "generated"
usb.present = "TRUE"
sound.present = "FALSE"
bios.bootOrder = "$bootOrder"
"@ | Set-Content -Path $vmx -Encoding ASCII

Write-Host "[+] VM created: $vmx" -ForegroundColor Green
Write-Host "    NIC is NAT (host build/download only). The RANGE itself stays isolated"  -ForegroundColor DarkGray
Write-Host "    on host-only libvirt networks INSIDE this VM."                            -ForegroundColor DarkGray

if ($Start) {
    $freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB,0)
    if ($freeMB -lt ($MemMB + 2048)) {
        Write-Warning ("Only {0} MB free; VM wants {1} MB (+overhead). Close apps or lower -MemMB, then start manually:" -f $freeMB,$MemMB)
        Write-Host "    `"$vmrun`" -T ws start `"$vmx`" gui" -ForegroundColor Yellow
        return
    }
    Write-Host "[*] Powering on..." -ForegroundColor Cyan
    & $vmrun -T ws start $vmx gui
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "vmrun start failed (exit $LASTEXITCODE). Check $VmDir\vmware.log"
        return
    }
    if ($Installed) {
        Write-Host "[+] Booting installed Ubuntu (login: range / your password)." -ForegroundColor Green
        if (-not $NoNested) { Write-Host "    Nested virt on: inside the VM 'kvm-ok' should now report acceleration usable." -ForegroundColor DarkGray }
    } else {
        Write-Host "[+] Booted. At the GRUB menu press 'e', append ' autoinstall' to the linux line, Ctrl-X." -ForegroundColor Green
        Write-Host "    (Unattended install then runs; ~10-20 min. Login: range / your password.)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "`nNext: review, then boot with:" -ForegroundColor Cyan
    Write-Host "  .\create-ubuntu-kvm-host.ps1 -Start        (after freeing RAM)" -ForegroundColor Yellow
    Write-Host "  or manually: `"$vmrun`" -T ws start `"$vmx`" gui" -ForegroundColor Yellow
}
