# PurpleRange on Ubuntu (KVM/QEMU + libvirt)

The Ubuntu-native port of the cyber range. Same isolated topology, same
sinkhole-vs-no-sinkhole scenarios, driven by `virsh`/`virt-install` instead of
VMware. **All traffic is synthetic and benign — no real malware, no real C2,
no real internet.**

## Host setup (Ubuntu 22.04/24.04)
```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst cpu-checker cloud-image-utils genisoimage
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"   # then re-login
kvm-ok                                  # must report acceleration usable
```
> Do **not** run this inside WSL2 or a nested guest — KVM acceleration isn't
> reliably available there. Use a bare-metal Ubuntu host or a hypervisor with
> nested-virt enabled.

## Base images
Base qcow2 images live in `CR_IMAGES_DIR` (default
`/var/lib/libvirt/images/cyberrange/base`). Because the range is offline, Linux
images have their service packages **pre-installed** (unbound, dnsmasq, inetsim)
— cloud-init only drops config + starts services, it does not apt-install.

Build them reproducibly with `images/build-images.sh` (needs `libguestfs-tools`):
```bash
sudo apt install -y libguestfs-tools
cd cyber-range/ubuntu/images
./build-images.sh --list                 # show manifest
DRY_RUN=1 ./build-images.sh               # preview
./build-images.sh                         # build debian12, ubuntu22, kali, opnsense (automated)
# assisted (you supply licensed/large ISOs):
WIN2022_ISO=/isos/ws2022-eval.iso VIRTIO_WIN_ISO=/isos/virtio-win.iso ./build-images.sh win2022
SO_ISO=/isos/securityonion.iso ./build-images.sh securityonion
```
| Image | How it's built |
|---|---|
| `debian12`, `ubuntu22`, `kali` | **Automated** — official cloud image + `virt-customize` |
| `opnsense` | **Automated** — OPNsense serial `.img` (no installer) |
| `win2022`, `win10`, `securityonion` | **Assisted** — you supply the ISO; script boots the installer (autounattend template provided for Windows) |

> `pfsense.qcow2` in `vms.tsv` can be replaced with the built `opnsense.qcow2`
> (edit the row) if you prefer the fully-automated firewall image.

## Layout
```
ubuntu/
  lib.sh                 # shared helpers + scenario settings
  inventory/
    networks.tsv         # 6 isolated libvirt networks
    vms.tsv              # trimmed 5-VM laptop set (full design: vms.full.tsv)
  00-preflight.sh        # verify KVM/libvirt/images/resources
  01-create-networks.sh  # virsh net-define/-start (isolated, no forward, no DHCP)
  02-deploy-vms.sh       # qcow2 overlays + cloud-init + virt-install --import
  03-boot-order.sh       # start/stop by dependency tier (+ snapshot revert)
  99-teardown.sh         # reset | clean | destroy | nuke
  scenario-toggle.sh     # flip Path A <-> Path B on SEC-GW
  validate.sh            # automated PASS/FAIL checklist per path
  benign-beacon.sh       # synthetic EICAR beacon (Linux endpoint)
config/                  # shared DNS/firewall configs (unbound, dnsmasq, inetsim)
```

## Quick start

### Option A - one-shot (recommended)
`deploy-range.sh` chains 00 -> 01 -> 02 -> (optional armed snapshot) -> 03 and
tees everything to `logs/deploy-<timestamp>.log`.
```bash
cd cyber-range/ubuntu
DRY_RUN=1 ./deploy-range.sh --snapshot-armed     # review the whole run first
./deploy-range.sh --snapshot-armed               # deploy + boot for real
# useful flags: --skip-preflight  --skip-boot  --revert <snap>  -n/--dry-run  -h
```

### Option B - stage by stage
```bash
./00-preflight.sh
DRY_RUN=1 ./01-create-networks.sh     # review, then run for real (sudo/libvirt)
./01-create-networks.sh
DRY_RUN=1 ./02-deploy-vms.sh          # review virt-install commands
./02-deploy-vms.sh
# configure guests, then snapshot 'scenario-armed' per VM:
#   for v in $(virsh list --all --name); do virsh snapshot-create-as "$v" scenario-armed; done
./03-boot-order.sh start scenario-armed
```

## Run an exercise
```bash
./scenario-toggle.sh A          # sinkhole ON  (contained)
#   on EP-INFECTED: ./benign-beacon.sh   then   ./validate.sh A
./scenario-toggle.sh B          # sinkhole OFF (beacon reaches attacker)
#   on EP-INFECTED: ./benign-beacon.sh   then   ./validate.sh B
```

## Reset / cleanup
```bash
./99-teardown.sh reset          # revert all to scenario-armed (fast)
./99-teardown.sh clean          # revert all to baseline-clean
./99-teardown.sh destroy --yes  # undefine VMs + remove overlays (export evidence first)
./99-teardown.sh nuke --yes     # also remove the libvirt networks
```

## Isolation guarantees
- libvirt networks have **no `<forward>`** — no NAT/route to the internet.
- Server/user/attacker/external segments have **no host bridge IP** (blind L2);
  only MGMT and SOC expose a host IP for admin/analyst access.
- SEC-GW (pfSense) is the only DHCP authority and enforces default-deny between
  zones; the internet is faked by EXT-INETSIM.
- `benign-beacon.sh` only sends a DNS query + an EICAR HTTP POST. No real payload.

Every script honors `DRY_RUN=1` to print exact commands without changing anything.
