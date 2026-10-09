#!/usr/bin/env bash
# Restore boot selection only; diagnostic packages are deliberately retained.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo'; exit 1; }
backup=/var/backups/j401-gmsl/stock-3g/extlinux.conf
test -s "$backup"
cp -a /boot/extlinux/extlinux.conf "/var/backups/j401-gmsl/extlinux.pre-rollback.$(date +%Y%m%dT%H%M%S)"
cp -a "$backup" /boot/extlinux/extlinux.conf
echo 'Original boot configuration restored. Reboot when ready.'
