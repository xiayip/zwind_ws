#!/usr/bin/env bash
# J401 Robotics / R39.2: PY.04 is MCP2518FD INT, not SPI CS1.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
grep -aq 'Seeed recomputer classic Robotics' /proc/device-tree/model
[[ $(uname -r) == 6.8.12-1021-tegra ]] || { echo 'Revalidate CAN pinmux for this kernel first' >&2; exit 1; }
# Clear only SFIO bit 10; preserve every other pin configuration bit.
value=$(busybox devmem 0x0243d020)
busybox devmem 0x0243d020 w "$((value & ~0x400))"
value=$(busybox devmem 0x0243d020)
(( (value & 0x400) == 0 ))
systemctl start zephyr-j401-can1-transceiver.service
