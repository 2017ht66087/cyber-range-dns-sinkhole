# PurpleRange — Isolated Cyber Range Deployment Kit

A repeatable, fully-isolated purple-team cyber range for VMware Workstation
(portable to vSphere/Proxmox). Runs the same infected-endpoint scenario **with**
and **without** a DNS sinkhole so SOC trainees can contrast containment and
visibility. **All traffic is synthetic and benign — no real malware, no real
C2, no real internet.**

> **Do not host this on Tails OS.** Tails is amnesic/RAM-only and Tor-routed —
> it cannot host persistent nested VMs and violates the "no real internet"
> rule. Host on VMware Workstation on a normal machine.

> **Do not mix labs on this PC.** `ODS-Ubuntu` is the CSI Nora / local-LLM box.
> `range-host` is the only place the cyber range should run (nested KVM).
> Tails is an unrelated privacy guest. Do not install CSI Nora on range-host,
> and do not put range VMs on ODS-Ubuntu or Tails.

## Host requirements
- VMware Workstation (provides `vmrun.exe` + `vnetlib64.exe`)
- This laptop uses a **trimmed** 5-VM inventory (~7 GB guests). Full 14-VM design
  is in `ubuntu/inventory/vms.full.tsv` and the `Enabled=$false` rows in
  `config/inventory.psd1`. Give `range-host` 8–12 GB before deploying.
- Base VM templates under `C:\CyberRange\Templates\<template>\<template>.vmx`
  (pfSense, Security Onion, Windows Server 2022, Windows 10, Debian 12,
  Ubuntu 22, Kali) — you supply these golden images and their licensing.

## Layout
```
cyber-range/
  config/      inventory.psd1 (source of truth) + DNS/firewall configs
  deploy/      00-preflight  01-create-networks  02-deploy-vms  03-boot-order  99-teardown
  scenario/    scenario-toggle.ps1  benign-beacon.ps1
  validate/    validate.ps1
  ansible/     inventory.ini  site.yml  (guest configuration)
```

## Quick start (elevated PowerShell on the VMware host)
```powershell
cd cyber-range\deploy
.\00-preflight.ps1                              # verify tooling/resources/templates
.\01-create-networks.ps1 -DryRun                # review VMnet commands, then run for real
.\01-create-networks.ps1
.\02-deploy-vms.ps1 -Linked                     # clone all VMs + baseline-clean snapshot
# configure guests from MGMT-ORCH:  ansible-playbook -i ansible/inventory.ini ansible/site.yml
# then snapshot 'scenario-armed' on each VM
.\03-boot-order.ps1 -Action Start -RevertTo scenario-armed
```

## Run an exercise
```powershell
# Path A — sinkhole ON (contained)
..\scenario\scenario-toggle.ps1 -Path A
#   on EP-INFECTED:  ipconfig /renew ; .\benign-beacon.ps1
..\validate\validate.ps1 -Path A

# Path B — sinkhole OFF (beacon reaches attacker)
..\scenario\scenario-toggle.ps1 -Path B
#   on EP-INFECTED:  ipconfig /renew ; .\benign-beacon.ps1
..\validate\validate.ps1 -Path B
```

## Reset / cleanup
```powershell
.\99-teardown.ps1 -Mode Reset      # revert all to scenario-armed (fast)
.\99-teardown.ps1 -Mode Clean      # revert all to baseline-clean
.\99-teardown.ps1 -Mode Destroy -Confirm   # delete all clones (export evidence first)
```

## Safety notes
- No VM has a bridged/NAT adapter — VMnets are host-only; attacker/external/
  users/servers segments have **no host adapter** (blind).
- `benign-beacon.ps1` only emits a DNS query + an HTTP POST of the EICAR test
  string. It does not download, persist, or self-replicate.
- Every `*.ps1` supports `-DryRun` (or shows exact commands) so you can review
  before anything executes. `vnetlib64` syntax varies by Workstation version —
  always `-DryRun` `01-create-networks.ps1` first.
