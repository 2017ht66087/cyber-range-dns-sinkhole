<#
.SYNOPSIS
    Build the NoCloud autoinstall seed ISO (cidata) for the Ubuntu KVM host VM.
    Windows has no ISO builder, so this uses the local Docker 'ubuntu' image to
    generate a SHA-512 password hash, substitute it into user-data, and run
    genisoimage. Produces .\seed.iso.
.EXAMPLE
    .\build-seed-iso.ps1 -Password 'ChangeMe123!'
#>
[CmdletBinding()]
param(
    [string]$Password = 'cyberrange',
    [string]$OutIso            # defaults to <script dir>\seed.iso (set in body;
)                             # $PSScriptRoot is empty during param binding)
$ErrorActionPreference = 'Stop'
if (-not $OutIso) { $OutIso = Join-Path $PSScriptRoot 'seed.iso' }

# Sanity: docker present?
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker not found. Install Docker Desktop, or build seed.iso on a Linux box with genisoimage."
}
if (-not (Test-Path "$PSScriptRoot\autoinstall\user-data")) { throw "autoinstall/user-data missing." }

Write-Host "[*] Building autoinstall seed ISO via Docker (hash + genisoimage)..." -ForegroundColor Cyan

# Build the ISO inside the container and emit it as base64 on STDOUT, then
# decode to bytes on the host. This avoids every Windows<->Docker pitfall:
# bind-mount write-back lag, `docker cp` colon/backslash path mangling, and
# native-process cwd. Inputs are bind-mounted read-only (reads are reliable);
# the ONLY stdout the script produces is the base64 blob.
$inner = @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq whois genisoimage >/dev/null 2>&1
HASH="$(mkpasswd -m sha-512 "$SEED_PASSWORD")"
mkdir -p /tmp/seed
ESC=$(printf '%s' "$HASH" | sed -e 's/[\/&]/\\&/g')
sed "s/@@PWHASH@@/$ESC/" /in/autoinstall/user-data > /tmp/seed/user-data
cp /in/autoinstall/meta-data /tmp/seed/meta-data
genisoimage -quiet -output /tmp/seed.iso -volid cidata -joliet -rock /tmp/seed/user-data /tmp/seed/meta-data 2>/dev/null
base64 -w0 /tmp/seed.iso
'@
$scriptPath = Join-Path $PSScriptRoot '.mkseed.sh'
[System.IO.File]::WriteAllText($scriptPath, ($inner -replace "`r`n","`n"))
Remove-Item $OutIso -ErrorAction SilentlyContinue
try {
    $b64 = & docker run --rm -e SEED_PASSWORD="$Password" -v "${PSScriptRoot}:/in:ro" ubuntu:22.04 bash /in/.mkseed.sh
} finally {
    Remove-Item $scriptPath -ErrorAction SilentlyContinue
}
$b64 = ($b64 -join '').Trim()
if ($b64) { [System.IO.File]::WriteAllBytes($OutIso, [Convert]::FromBase64String($b64)) }

if (Test-Path $OutIso) {
    $kb = [math]::Round((Get-Item $OutIso).Length/1KB,0)
    Write-Host "[+] Seed ISO ready: $OutIso ($kb KB)" -ForegroundColor Green
    Write-Host "    Host login will be  user: range  /  password: $Password" -ForegroundColor DarkGray
} else {
    throw "seed.iso was not produced."
}
