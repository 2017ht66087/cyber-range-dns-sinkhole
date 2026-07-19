# Kubernetes Cyber Range — DNS Sinkhole Exercise

A self-contained, single-node (k3s) cyber range that demonstrates the security
value of a **DNS sinkhole**, in two ConfigMap-toggled variants:

- **Variant A — sinkhole ON (contained):** the firewall intercepts the malicious
  C2 lookup, returns a sinkhole IP, and logs the capture. The beacon is neutralized.
- **Variant B — sinkhole OFF (uncontained):** the malicious lookup is forwarded
  to the attacker-aware external resolver, resolves to the real attacker IP, and
  the endpoint would beacon out. This is the "what goes wrong" path.

The container image is the same for both — only the `range-mode` ConfigMap changes.

## Architecture

```
 namespace: cyber-range                          namespace: dns-system
 ┌───────────────┐   DNS :8053   ┌───────────────┐   :53   ┌───────────────┐
 │  infected-pc  │ ────────────► │  firewall-sim │ ──────► │  internal-dns │  (benign)
 │ (beaconing)   │               │ (policy       │         └───────────────┘
 └───────┬───────┘               │  engine,      │   :53   ┌───────────────┐
         │ callback (denied)     │  ConfigMap)   │ ──────► │  external-dns │  (attacker C2)
         ▼                       └──────┬────────┘         └───────────────┘
   SINKHOLE_IP / attacker              │ capture :8080
   (off-cluster, blocked)              ▼
                              ┌───────────────┐
                              │   sinkhole    │  (logs captures)
                              └───────────────┘
```

- **infected-pc** — simulated compromised endpoint; asks `firewall-sim` to
  resolve the malicious domain, then attempts a C2 callback and logs the verdict.
- **firewall-sim** — DNS policy engine on `:8053`. Behavior driven by the
  `range-mode` ConfigMap (`SINKHOLE_ENABLED`). Sinkholes or forwards accordingly.
- **internal-dns** — resolves benign/corporate domains; refuses the malicious one.
- **external-dns** — attacker-aware public resolver; maps the malicious domain to
  the attacker IP (`203.0.113.66`, TEST-NET-3).
- **sinkhole** — HTTP capture endpoint on `:8080`; logs interceptions.
- **NetworkPolicies** — default-deny egress in `cyber-range`, re-opening only
  CoreDNS, `infected-pc→firewall`, and `firewall→{dns-system, sinkhole}`. The
  actual off-cluster C2 callback stays denied — that is the containment.

> All addresses are fake/reserved (TEST-NET / RFC5737, `10.255.255.10`). Nothing
> talks to the real internet; the range is self-contained.

## Prerequisites

An **Ubuntu guest** (20.04/22.04/24.04) in VMware Workstation with internet
(NAT) for the initial image pulls. **No nested virtualization needed** — k3s runs
containers directly in the guest kernel.

## Quick start (run inside the Ubuntu guest)

```bash
cd cyber-range/k8s/scripts
chmod +x *.sh

./01-install-k3s.sh          # install k3s + Docker, wait for node Ready
#   log out/in (or: newgrp docker) so docker works without sudo
./02-build-images.sh         # build 5 images, import into k3s containerd

./03-deploy.sh with          # Variant A: sinkhole ENABLED
./validate.sh                # observe: CONTAINED, sinkhole captures logged

./toggle-variant.sh without  # flip to Variant B: sinkhole DISABLED
./validate.sh                # observe: UNCONTAINED, resolves to attacker IP
```

## What you should see

**Variant A (with):**
```
[infected-pc]  [CONTAINED] teq.xyz.com -> 10.255.255.10 (SINKHOLE). C2 callback blocked ...
[firewall-sim] [SINKHOLE] intercepted teq.xyz.com from 10.42.x.x -> 10.255.255.10 (contained)
[sinkhole]     CAPTURE POST /capture ... body={'event':'dns-intercept','domain':'teq.xyz.com',...}
```

**Variant B (without):**
```
[infected-pc]  [UNCONTAINED] teq.xyz.com -> 203.0.113.66 (attacker C2) ... malware would exfiltrate.
[firewall-sim] [ALERT] malicious teq.xyz.com ... forwarded via EXTERNAL -> A 203.0.113.66 (NO sinkhole ...)
[external-dns] resolve teq.xyz.com -> 203.0.113.66 (ATTACKER C2)
```

## Run both variants side by side (optional)

The included manifests use a single `range-mode` ConfigMap and shared Deployment
names (clean toggle model). To run both at once instead, duplicate the
`cyber-range` resources into two namespaces (e.g. `range-sinkhole` /
`range-nosinkhole`), each with its own `range-mode` ConfigMap. The same pattern
applies — config-driven behavior, service-based DNS, egress restriction.

## Files

```
k8s/
├── images/            # Dockerfiles + Python app code for the 5 images
│   ├── infected-pc/   (client.py)
│   ├── internal-dns/  (dns.py)  external-dns/ (dns.py)
│   ├── firewall-sim/  (firewall.py)
│   └── sinkhole/      (server.py)
├── manifests/         # namespace, deployments/services, networkpolicy, 2 configmaps
└── scripts/           # 01-install-k3s, 02-build-images, 03-deploy, toggle-variant, validate, teardown
```

## Notes & caveats

- **NetworkPolicy enforcement:** k3s ships a policy controller, so the egress
  lockdown is enforced. On a cluster whose CNI ignores NetworkPolicy, the range
  still runs but without the containment guarantee.
- **Images use `imagePullPolicy: IfNotPresent`** and are imported straight into
  k3s' containerd (namespace `k8s.io`) — no external registry required.
- **Teardown:** `./teardown.sh` (workloads) or `./teardown.sh --nuke` (also
  removes k3s).
