<#
.SYNOPSIS
    Flip the range between Path A (sinkhole ON) and Path B (sinkhole OFF).
    This pushes: (1) the DHCP DNS server handed to the USERS zone, and
    (2) the enable/disable state of firewall rules R4/R6 on SEC-GW.
.DESCRIPTION
    SEC-GW is driven over SSH (pfSense/OPNsense). Provide the gateway's MGMT IP
    and credentials/key. The heavy lifting is two small config pushes; the
    actual malicious-domain resolution difference comes from which DNS server
    the endpoints use, which is set here.
.EXAMPLE
    .\scenario-toggle.ps1 -Path A   # sinkhole ON  (contained)
    .\scenario-toggle.ps1 -Path B   # sinkhole OFF (beacon reaches attacker)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('A','B')][string]$Path,
    [string]$GatewayHost = '10.10.10.1',
    [string]$GatewayUser = 'admin',
    [switch]$DryRun
)
. "$PSScriptRoot\..\deploy\_common.ps1"
$inv = Get-RangeInventory
$s   = $inv.Settings

if ($Path -eq 'A') {
    $dns = $s.InternalDNS; $r4 = 'disable'; $r6 = 'disable'
    $desc = "Path A / SINKHOLE ON  -> USERS DNS=$dns ; malicious -> $($s.SinkholeIP) ; C2 blocked"
} else {
    $dns = $s.ExternalDNS; $r4 = 'enable';  $r6 = 'enable'
    $desc = "Path B / SINKHOLE OFF -> USERS DNS=$dns ; malicious -> $($s.AttackerIP) ; C2 reachable"
}

Write-Step $desc

# Commands executed on SEC-GW (pfSense easyrule / OPNsense configctl style).
# Adjust to your gateway's automation surface; kept explicit for auditability.
$remoteCmds = @(
    "# set USERS-zone DHCP DNS to $dns",
    "pfSsh.php playback setdhcpdns $($s.UsersVMnet) $dns",
    "# R4 (USERS->EXT-DNS 53) and R6 (USERS->ATK-C2) => $r4",
    "pfSsh.php playback rule USERS EXT-DNS $r4",
    "pfSsh.php playback rule USERS ATK-C2 $r6",
    "# reload",
    "pfctl -f /tmp/rules.debug ; /etc/rc.newwanip"
)

if ($DryRun) {
    Write-Host "    DRYRUN - would SSH $GatewayUser@$GatewayHost and run:" -ForegroundColor DarkGray
    $remoteCmds | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
} else {
    $script = ($remoteCmds -join "`n")
    Write-Step "Pushing config to SEC-GW ($GatewayUser@$GatewayHost) via SSH"
    $script | ssh "$GatewayUser@$GatewayHost" 'sh -s'
    Write-Ok "Toggle applied. Renew DHCP on endpoints (ipconfig /renew) to pick up DNS=$dns."
}

Write-Ok "Scenario set to Path $Path."
Write-Host "    Verify from EP-INFECTED:  nslookup $($s.MaliciousDomains[0])" -ForegroundColor DarkGray
Write-Host "    Expected: Path A -> $($s.SinkholeIP)   |   Path B -> $($s.AttackerIP)" -ForegroundColor DarkGray
