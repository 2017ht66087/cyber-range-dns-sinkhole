# Unified field map (IR dictionary)

Use this when writing hunts or when a vendor field is missing. Empty source
cells mean “not present on that path; derive or leave blank.”

| Meaning | ASIM Web Session | Akamai JSON (`AkamaiSIEMEvent`) | CEF (`CommonSecurityLog`) | Plain syslog |
|---|---|---|---|---|
| Vendor / product | `EventVendor`, `EventProduct` | `"Akamai"`, `"WAF"` | `DeviceVendor`, `DeviceProduct` | hostname / app-name |
| Event time | `TimeGenerated`, `EventStartTime` | event / request time | `TimeGenerated` / syslog ts | PRI timestamp |
| Client IP | `SrcIpAddr` | `attackData.clientIP` | `SourceIP` / `src` | unstructured |
| Client IPv6 | `SrcIpAddr` | `attackData.clientIP` if v6 | `c6a2` | |
| Host header | `DstHostname` | `httpMessage.host` | `DestinationHostName` / `dhost` | |
| URL | `Url` | `tls?https:http` + host + path + query | `RequestURL` / `request` | |
| HTTP method | `HttpRequestMethod` | `httpMessage.method` | `RequestMethod` | |
| Protocol | `NetworkProtocol` / `HttpVersion` | `httpMessage.protocol` | `ApplicationProtocol` / `app` | |
| User-Agent | `HttpUserAgent` | `httpMessage.userAgent` | `RequestClientApplication` | |
| WAF action | `DvcAction` | `attackData.appliedAction` | `DeviceAction` / `act` | |
| Rule IDs | `ThreatId` | `attackData.rules` | `cs1` (`DeviceCustomString1`) | |
| Rule messages | `ThreatName` | `attackData.ruleMessages` | `cs2` | |
| Rule data | `ThreatField` / additional | `attackData.ruleData` | `cs3` | |
| Selectors | additional | `attackData.ruleSelectors` | `cs4` | |
| Client reputation | additional | `attackData.clientReputation` | `cs5` | |
| Request ID | `EventOriginalUid` | `httpMessage.requestId` | `devicePayloadId` | |
| HTTP status | `EventResultDetails` | status if present | custom / flex | |
| Success / fail | `EventResult` | derived from action | derived from `DeviceAction` | |
| Geo country | `SrcGeoCountry` | geo object if present | `SourceGeoCountry` if enriched | |

CEF header used by Akamai’s connector:

```
CEF:0|Akamai|akamai_siem|1.0|<eventClassId>|<name>|<severity>
```

Reference: [Akamai SIEM CEF connector](https://techdocs.akamai.com/siem-integration/docs/siem-cef-connector),
[ASIM Web Session schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-web).
