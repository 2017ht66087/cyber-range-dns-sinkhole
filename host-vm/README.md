# Ubuntu KVM Host VM (runs the range on this Windows box)

This turns your local `ubuntu-24.04.4-live-server-amd64.iso` into a nested
**KVM host** inside the already-installed VMware Workstation. The Ubuntu range
kit (`../ubuntu/`) then runs *inside* this VM.

```
Windows 11 host
  └─ VMware Workstation
       └─ range-host  (Ubuntu 24.04, nested virt: vhv.enable=TRUE)   <-- built here
            └─ KVM/libvirt
                 └─ isolated cyber range (SEC-GW, SVC-*, EP-*, ATK-C2, ...)
```

## Why nested / why NAT on the host VM
- The host VM's single NIC is **NAT** — used only so Ubuntu can install and so
  `build-images.sh` can download cloud images. The **range itself never uses it**:
  the range lives on host-only libvirt networks *inside* this VM with no forward.
- Isolation is preserved: nothing in the range can reach your LAN/internet.

## Reality check for THIS laptop (i7-1265U, 32 GB, ~7 GB free now)
- You **cannot** run all 14 range VMs nested here (~41 GB RAM design).
- Free memory first (close Docker Desktop, browsers, etc.), then give the host
  VM 8-12 GB and run a **trimmed range**: `SEC-GW`, `SVC-DC`/`SVC-SINK`,
  `EXT-DNS`, `EP-INFECTED`, and a light log collector. Edit `../ubuntu/inventory/vms.tsv`
  (comment rows / lower mem) before deploying.

## Steps
```powershell
cd cyber-range\host-vm

# 1) Build the autoinstall seed ISO (uses Docker; sets user 'range')
.\build-seed-iso.ps1 -Password 'ChangeMe123!'

# 2) Create the VMware host VM (nested virt, both ISOs attached)
.\create-ubuntu-kvm-host.ps1 -MemMB 10240 -Cpu 6 -DiskGB 200

# 3) Boot it (only after freeing RAM). At GRUB press 'e', append ' autoinstall'
#    to the 'linux' line, Ctrl-X. Unattended install runs (~10-20 min).
.\create-ubuntu-kvm-host.ps1 -MemMB 10240 -Cpu 6 -Start
```

## Inside range-host (after install, login: range / your password)
```bash
# copy the kit in (from Windows, e.g. via scp/WinSCP to /home/range/cyber-range)
cd ~/cyber-range/ubuntu
./00-preflight.sh
./images/build-images.sh                 # debian12, ubuntu22, kali, opnsense
./deploy-range.sh --snapshot-armed       # trimmed inventory recommended here
./scenario-toggle.sh A                   # then B ; ./validate.sh A|B
```

## Files
- `autoinstall/user-data` — subiquity autoinstall (installs qemu-kvm/libvirt/virtinst/libguestfs, user `range`)
- `autoinstall/meta-data` — NoCloud metadata
- `build-seed-iso.ps1` — builds `seed.iso` (Docker: hash password + genisoimage)
- `create-ubuntu-kvm-host.ps1` — writes vmdk + .vmx (nested virt) and boots via vmrun

## Notes
- `vhv.enable=TRUE` requires VT-x exposed to VMware. If nested KVM reports no
  acceleration, enable "Virtualize Intel VT-x/EPT" for the VM and ensure VT-x is
  on in firmware.
- The one manual step (adding `autoinstall` at GRUB) is required because VMware
  can't inject kernel args into an unmodified ISO. Everything after is hands-off.
