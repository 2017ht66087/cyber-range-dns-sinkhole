# SEC-GW Firewall Rule Matrix (default-deny)

Apply on pfSense/OPNsense. Interface mapping:

| Interface | VMnet | Zone | Subnet |
|---|---|---|---|
| WANless_MGMT | VMnet10 | MGMT | 10.10.10.0/24 |
| SERVERS | VMnet11 | SERVERS | 10.10.20.0/24 |
| USERS | VMnet12 | USERS | 10.10.30.0/24 |
| ATTACKER | VMnet13 | ATTACKER | 10.10.40.0/24 |
| EXTERNAL | VMnet14 | EXTERNAL | 10.10.50.0/24 |
| SOC | VMnet15 | SOC | 10.10.60.0/24 |

> There is intentionally **no WAN interface**. The range has no route to the real internet.

## Rules (top-down, first match; each interface ends with default-deny + log)

| # | Interface (src) | Source | Destination | Port/Proto | Action | Notes |
|---|---|---|---|---|---|---|
| R1 | MGMT | 10.10.10.0/24 | any zone | 22,3389,5985-5986,443 | PASS | Admin from bastion only |
| R2 | any | any | 10.10.20.20 (SVC-LOG) | 514/udp,1514/tcp,443 | PASS | Central logging |
| R3 | USERS | 10.10.30.0/24 | 10.10.20.10 (SVC-DC) | 53,88,389,445,135 | PASS | AD auth + internal DNS (full design only) |
| R3b | USERS | 10.10.30.0/24 | 10.10.20.11 (SVC-SINK) | 53 | PASS | Laptop trim: Path A DNS is SVC-SINK (SVC-DC not deployed) |
| R4 | USERS | 10.10.30.0/24 | 10.10.50.53 (EXT-DNS) | 53 | PASS/BLOCK | **Scenario toggle** (Path B only) |
| R5 | USERS | 10.10.30.0/24 | 10.10.50.80 (INetSim) | 80,443 | PASS | Mock internet browsing |
| R6 | USERS | 10.10.30.0/24 | 10.10.40.10 (ATK-C2) | 80,443 | PASS/BLOCK | **Scenario toggle** (Path B only) |
| R7 | SOC | 10.10.60.0/24 | any | via SPAN/mirror | PASS | Passive capture |
| R8 | SERVERS | 10.10.20.11 (SINK) | 10.10.60.5 (sink IP) | 80,443 | PASS | Sinkhole callback capture (Path A) |
| D0 | ALL | any | any | any | **BLOCK + LOG** | Default deny on every interface |

## Scenario toggle mapping (see scenario/scenario-toggle.ps1)
- **Path A (sinkhole ON):** R4 = BLOCK, R6 = BLOCK, endpoints' DHCP DNS = 10.10.20.11 (SVC-SINK on this laptop; 10.10.20.10 if SVC-DC is restored).
- **Path B (sinkhole OFF):** R4 = PASS, R6 = PASS, endpoints' DHCP DNS = 10.10.50.53.

## Aliases to define
- `SinkholeIP = 10.10.60.5`, `InternalDNS = 10.10.20.10`, `ExternalDNS = 10.10.50.53`, `AttackerC2 = 10.10.40.10`.
