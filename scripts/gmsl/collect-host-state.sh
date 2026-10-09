#!/usr/bin/env bash
# Read-only host evidence collection; run as root for complete kernel logs.
set -u
date -Is
uname -a
cat /etc/nv_tegra_release
printf '\n--- boot ---\n'
cat /boot/extlinux/extlinux.conf
printf '\n--- V4L2 ---\n'
ls -l /dev/video* /dev/media* 2>/dev/null
v4l2-ctl --list-devices
media-ctl -p
for device in /dev/video*; do
  [[ -e "$device" ]] || continue
  v4l2-ctl -d "$device" --all --list-formats-ext
done
printf '\n--- I2C registered devices ---\n'
for node in /sys/bus/i2c/devices/*/name; do
  printf '%s: %s\n' "$node" "$(cat "$node")"
done
printf '\n--- camera kernel log ---\n'
journalctl -k -b --no-pager | grep -Ei 'max967|gmsl|nv.cam|camera|nvcsi|capture|pca954|vi-output'
printf '\n--- GPIO ---\n'
cat /sys/kernel/debug/gpio 2>/dev/null
printf '\n--- containers ---\n'
docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'
