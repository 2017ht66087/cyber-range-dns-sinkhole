#!/usr/bin/env bash
# One-time: grant the range user passwordless sudo (uses the seed password once).
set -e
printf 'cyberrange\n' | sudo -S -p '' bash -c 'echo "range ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/range; chmod 440 /etc/sudoers.d/range'
sudo -n true && echo NOPASSWD_OK
