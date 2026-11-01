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

## Corp servers (namespace `corp`): thin AD, DB and web

Two of each, as lightweight containers instead of VMs (they replace the disabled
`SVC-DC` VM in `config/inventory.psd1`). Defined in `manifests/corp-servers.yaml`,
deployed by `03-deploy.sh`, checked by `validate.sh`.

| Host (`*.corp.lab`) | What | Image | Mem req / limit |
|---|---|---|---|
| dc01 `10.43.200.11` | Samba AD DC, provisions realm `CORP.LAB` / domain `CORP` | `corp-samba-dc` (Alpine) | 160 / 384 Mi |
| dc02 `10.43.200.12` | Samba AD DC, joins dc01 (DRS replication) | `corp-samba-dc` | 160 / 384 Mi |
| db01 `10.43.200.21` | PostgreSQL 16, `hr.employees` + private `hr.payroll` | `postgres:16-alpine` | 48 / 160 Mi |
| db02 `10.43.200.22` | MariaDB 11.4, `crm.customers` + `crm.orders` | `mariadb:11.4` | 96 / 256 Mi |
| web01 `10.43.200.31` | nginx intranet; `/app/` proxies to web02 | `nginx:1.27-alpine` | 8 / 32 Mi |
| web02 `10.43.200.32` | stdlib-Python HR portal reading db01 + db02 | `corp-web02` | 16 / 64 Mi |

Together they use about 0.4 GiB in practice (1.25 GiB worst case at the limits).

- **AD:** demo users `alice` (IT-Admins), `bob` (Finance), `svc-sql` (with SPN
  `postgres/db01.corp.lab`, so it can be Kerberoasted) and `da-test` (Domain Admins).
  The DCs keep their state on local-path PVCs and register their fixed Service
  ClusterIPs in AD DNS (DCE/RPC is pinned to 49152/49153), so replication
  survives pod restarts. Sysvol ACLs are stored in a tdb, so the pods don't need
  `CAP_SYS_ADMIN`.
- **Credentials:** `scripts/corp-secrets.sh` generates random passwords into the
  Secret `corp/corp-credentials` and a copy in `~/.corp-lab-credentials`
  (mode 600). None of these passwords are stored in git.
- **DNS:** internal-dns answers `<host>.corp.lab` (and `corp.lab` itself, which
  points at dc01) with the Service IPs. The DCs also serve the full AD zone
  (SRV records) themselves.
- **Access:** intranet on the host at `http://<node-ip>:30088/` (only reachable
  from the VMnet8 subnet). Everything else is ClusterIP only.
- **NetworkPolicy:** corp is default-deny in both directions, except traffic
  inside corp, DNS to CoreDNS, kubelet probes and the NodePort. corp has no
  internet egress. **Lateral movement** from `infected-pc` (DNS, Kerberos, LDAP,
  SMB, both DBs and HTTP) is opt-in: `kubectl apply -f manifests/corp-lateral.yaml`
  or `CORP_LATERAL=1 ./03-deploy.sh`.

```bash
sudo k3s kubectl -n corp exec deploy/dc01 -- samba-tool drs showrepl --summary
sudo k3s kubectl -n corp exec deploy/dc02 -- samba-tool user list
curl http://192.168.9.50:30088/app/        # web01 -> web02 -> db01/db02
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
│   ├── sinkhole/      (server.py)
│   └── corp-samba-dc/ (entrypoint.sh)  corp-web02/ (app.py)
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
