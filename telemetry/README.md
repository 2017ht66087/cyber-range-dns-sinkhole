# Telemetry parsers — IR, threat hunting, IoC identification

Incident Response pack for the Microsoft security stack. It turns **Akamai WAF**
and **Sentinel syslog/CEF** (different wire formats) into one **ASIM Web Session**
view so hunters query once, then pivot to IoCs.

All traffic described here is defensive telemetry. Nothing in this folder is a
payload or an exploit.

## Why the formats differ

Sentinel does not emit a native “Sentinel syslog.” It **ingests** syslog.
Akamai WAF does not speak that format.

| Source | Native format | Transport | Sentinel table |
|---|---|---|---|
| Sentinel Syslog via AMA | RFC 3164 / 5424 | UDP/TCP 514 → Linux forwarder → AMA | `Syslog` |
| Sentinel CEF via AMA | CEF inside syslog | TCP 514 → AMA | `CommonSecurityLog` |
| Akamai SIEM Integration | JSON (`attackData`, `httpMessage`) | Pull API (EdgeGrid) | `AkamaiSIEMEvent` (CCF connector) |
| Akamai CEF connector | Same JSON, converted to CEF | Syslog CEF → your collector | `CommonSecurityLog` |

Do **not** send raw Akamai JSON into the plain Syslog connector. It lands as an
unparsed blob and IoC field searches fail.

## Ingest paths into the Microsoft stack

**Path A (preferred)** — Content Hub → **Akamai Security Events** (CCF).
EdgeGrid credentials + config ID. Events land in `AkamaiSIEMEvent`.

**Path B** — Akamai [SIEM CEF connector](https://techdocs.akamai.com/siem-integration/docs/siem-cef-connector)
→ Linux VM TCP 514 → **CEF via AMA** → `CommonSecurityLog` (`DeviceVendor == "Akamai"`).

Then, in both cases, install the parsers below so `_Im_WebSession` includes Akamai.

```
Akamai WAF
  ├─ Path A: SIEM API ── CCF ──► AkamaiSIEMEvent
  └─ Path B: SIEM API ── CEF connector ── syslog/CEF ── AMA ──► CommonSecurityLog
                         │
                         ▼
              ASIM parsers in parsers/
                         │
                         ▼
                   _Im_WebSession
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
     Sentinel       Defender XDR    SOAR playbooks
     hunting/IoC    incident sync   (optional)
```

## Install in Sentinel (IR runbook)

1. Ingest via Path A and/or Path B (see above). Confirm rows in
   `AkamaiSIEMEvent` or `CommonSecurityLog | where DeviceVendor == "Akamai"`.
2. Sentinel → **Functions** → New → paste each file in `parsers/` as a workspace
   function with the same name as the file (without `.kql`).
3. If you already use ASIM, add `ASimWebSessionAkamai` to the unifying
   `_Im_WebSession` / `vimWebSession` parser list (Content Hub → ASIM, or
   append a `union` in your workspace wrapper).
4. Import `hunting/*.kql` as hunting queries. Import `ioc/*.kql` as saved
   searches or analytics rules.
5. Create a watchlist named `IR_IoC` with columns `IoCType`, `IoCValue`,
   `ThreatName`, `Confidence`, `Source` (see `ioc/watchlist-IR_IoC.example.csv`).
6. Optional: Sentinel → Settings → connect **Microsoft Defender XDR** so
   analytics incidents sync into the XDR queue.

## Folder

```
telemetry/
  README.md
  field-map.md                         unified field dictionary
  parsers/
    ASimWebSessionAkamai.kql           Path A: AkamaiSIEMEvent → ASIM
    ASimWebSessionAkamaiCEF.kql        Path B: CommonSecurityLog → ASIM
    vimWebSessionUnified.kql           hunter-facing union
  hunting/
    websession-threat-hunt.kql
    beacon-and-rare-url.kql
  ioc/
    identify-iocs.kql
    watchlist-match.kql
    watchlist-IR_IoC.example.csv
```

## Hunter entry point

```kusto
_Im_WebSession
| where TimeGenerated > ago(24h)
| where DvcAction in ("deny", "block", "alert")
| summarize Hits=count() by SrcIpAddr, Url, ThreatName, DvcAction
```

If `_Im_WebSession` is not installed yet, use `vimWebSessionUnified` from this pack.

## Range lab vs production

The k3s range on range-host emits **synthetic** beacons and sinkhole captures
(`http://192.168.9.50:30080/api/captures`). Those are for exercise evidence only.
This pack is for **production** Akamai + Sentinel telemetry. Do not mix the two
in the same analytics rule without a `EventProduct` filter.
