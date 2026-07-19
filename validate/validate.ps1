<#
.SYNOPSIS
    Automated validation checklist for the range. Runs the §9 checks for the
    active scenario path and prints a PASS/FAIL report.
.DESCRIPTION
    Intended to run FROM EP-INFECTED (or a host on the USERS zone). Confirms
    isolation, correct DNS resolution for the active path, and callback
    reachability. Use -Path to state which scenario you set with scenario-toggle.
.EXAMPLE
    .\validate.ps1 -Path A
    .\validate.ps1 -Path B
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('A','B')][string]$Path)

$invPath = Join-Path $PSScriptRoot '..\config\inventory.psd1'
$inv = Import-PowerShellDataFile -Path $invPath
$s   = $inv.Settings
$domain = $s.MaliciousDomains[0]
$results = New-Object System.Collections.Generic.List[object]

function Add-Check { param($Name,$Ok,$Detail)
    $results.Add([pscustomobject]@{ Check=$Name; Result=($(if($Ok){'PASS'}else{'FAIL'})); Detail=$Detail }) }

# --- Isolation: real internet must be unreachable ---
$net = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue
Add-Check 'Isolation: no route to real internet (8.8.8.8)' (-not $net) "reachable=$net (expected False)"

# --- DNS resolution matches the active path ---
$expected = if ($Path -eq 'A') { $s.SinkholeIP } else { $s.AttackerIP }
try {
    $resolved = (Resolve-DnsName -Name $domain -ErrorAction Stop | Select-Object -First 1).IPAddress
} catch { $resolved = $null }
Add-Check "DNS: $domain resolves to expected ($expected)" ($resolved -eq $expected) "got=$resolved"

# --- Callback reachability differs by path ---
$cbOk = $false
try {
    Invoke-WebRequest "http://$domain/checkin" -Method POST -Body 'test' -TimeoutSec 5 -UseBasicParsing | Out-Null
    $cbOk = $true
} catch { $cbOk = $false }

if ($Path -eq 'A') {
    Add-Check 'Containment: C2 callback BLOCKED (Path A)' (-not $cbOk) "callbackSucceeded=$cbOk (expected False)"
} else {
    Add-Check 'Exposure: C2 callback SUCCEEDS (Path B)'   ($cbOk)     "callbackSucceeded=$cbOk (expected True)"
}

# --- Report ---
Write-Host "`n=== Cyber Range Validation - Path $Path ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$fail = ($results | Where-Object Result -eq 'FAIL').Count
if ($fail -eq 0) { Write-Host "ALL CHECKS PASSED for Path $Path." -ForegroundColor Green; exit 0 }
else { Write-Host "$fail check(s) FAILED for Path $Path. Review above." -ForegroundColor Red; exit 1 }
