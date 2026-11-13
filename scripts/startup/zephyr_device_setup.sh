#!/usr/bin/env bash
set -euo pipefail
modprobe can
modprobe can_raw
modprobe mttcan

CAN0_BITRATE=1000000
CAN1_BITRATE=1000000
if grep -aq 'Seeed recomputer classic Robotics' /proc/device-tree/model 2>/dev/null; then
    modprobe spi_tegra114
    modprobe mcp251xfd
    # Device probing can finish after the boot service starts.
    for attempt in {1..100}; do
        [[ -e /sys/class/net/can1 ]] && break
        sleep 0.1
    done
    [[ -e /sys/class/net/can1 ]] || { echo "CAN1 did not appear" >&2; exit 1; }
    # Keep the CAN1 SPI controller awake: runtime resume adds millisecond-scale
    # delays to the arm's 5 ms command batches on the validated J401 BSP.
    can1_spi_device=$(readlink -f /sys/class/net/can1/device)
    can1_spi_controller=${can1_spi_device%%/spi_master/*}
    can1_spi_power_control="$can1_spi_controller/power/control"
    if [[ "$can1_spi_controller" == "$can1_spi_device" || ! -f "$can1_spi_power_control" ]]; then
        echo "Cannot locate CAN1 SPI controller runtime-power setting: $can1_spi_device" >&2
        exit 1
    fi
    if ! printf 'on\n' > "$can1_spi_power_control"; then
        echo "Cannot keep CAN1 SPI controller powered: $can1_spi_power_control" >&2
        exit 1
    fi
    if [[ "$(< "$can1_spi_power_control")" != "on" ]]; then
        echo "CAN1 SPI controller runtime-power setting did not remain on" >&2
        exit 1
    fi
    # Set INT to GPIO before opening MCP2518FD, otherwise IRQ may be disabled.
    ip link set can1 down
    /etc/systemd/zephyr_j401_can_prepare.sh
    # Current wiring: CAN0 Ranger Mini V3, CAN1 RS arm.
    CAN0_BITRATE=500000
fi

ip link set can0 down
ip link set can0 type can bitrate "$CAN0_BITRATE"
ip link set can0 txqueuelen 1000
ip link set can0 up
ip link set can1 down
ip link set can1 type can bitrate "$CAN1_BITRATE" loopback off listen-only off
ip link set can1 txqueuelen 1000
ip link set can1 up
