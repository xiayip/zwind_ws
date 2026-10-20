#!/usr/bin/env bash
# Install: sudo bash setup_j401_can.sh
# Roll back SPI module override: sudo bash setup_j401_can.sh rollback
# No live module reload or reboot. Reboot separately to activate at boot.
# Validated: Seeed Robotics J401, R39.2, kernel 6.8.12-1021-tegra.
# Origin: https://forums.developer.nvidia.com/t/jetson-orin-nano-spi-speed-not-changing/311083/9
# The newer two SW-CS patches did NOT restore loopback on this board.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL=6.8.12-1021-tegra
[[ $(uname -r) == "$KERNEL" ]] || { echo "Unsupported kernel: $(uname -r)" >&2; exit 1; }
grep -aq 'Seeed recomputer classic Robotics' /proc/device-tree/model || { echo 'Unsupported board' >&2; exit 1; }
STATE=/var/lib/zephyr/j401-can
TARGET=/lib/modules/$KERNEL/updates/zephyr/spi-tegra114.ko
mkdir -p "$STATE"
if [[ ${1:-install} == rollback ]]; then
    # Original vendor module is never overwritten. Runtime pinmux fix remains
    # because it is independently required; this rolls back only the CS patch.
    rm -f "$TARGET"
    depmod -a "$KERNEL"
    echo 'Vendor SPI module selected for next boot; pinmux/standby setup retained.'
    exit 0
fi
[[ ${1:-install} == install ]] || { echo 'Usage: setup_j401_can.sh [install|rollback]' >&2; exit 1; }
for cmd in curl sha256sum patch make gcc modinfo depmod busybox gpioset; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
# libgpiod v1 syntax is required by the persistent standby service.
gpioset --help | grep -q -- '--mode' || { echo 'libgpiod v1 required' >&2; exit 1; }
HEADERS=/usr/src/linux-headers-$KERNEL-ubuntu24.04_aarch64/3rdparty/canonical/linux-noble
[[ -f "$HEADERS/Module.symvers" && -f "$HEADERS/include/generated/autoconf.h" ]] || { echo "Missing prepared headers: $HEADERS" >&2; exit 1; }
# This BSP loads SPI from rootfs. Do not silently leave an old module in initrd.
if [[ -f /boot/initrd ]]; then
    command -v lsinitramfs >/dev/null
    lsinitramfs /boot/initrd > "$STATE/initrd-files.txt"
    if grep -q 'spi-tegra114\.ko' "$STATE/initrd-files.txt"; then
        echo 'SPI module is in initrd; this image requires a separate initrd update.' >&2
        exit 1
    fi
fi
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
URL=https://gitlab.com/nvidia/nv-tegra/3rdparty/canonical/linux-noble/-/raw/l4t/l4t-r39.2-Ubuntu-nvidia-tegra-6.8.0-1021.21/drivers/spi/spi-tegra114.c
curl --fail --location --retry 3 --max-time 120 "$URL" -o "$BUILD/spi-tegra114.c"
echo "b68a841766617725666a939f98f8e0647bef490210e8eb52fae41dae0d7fedfb  $BUILD/spi-tegra114.c" | sha256sum -c -
patch --batch --fuzz=0 -d "$BUILD" -p1 < "$DIR/j401-spi-hw-cs.patch"
printf 'obj-m += spi-tegra114.o\n' > "$BUILD/Makefile"
make -C "$HEADERS" M="$BUILD" modules -j2
ORIGINAL=/lib/modules/$KERNEL/kernel/drivers/spi/spi-tegra114.ko
[[ $(modinfo -F vermagic "$BUILD/spi-tegra114.ko") == "$(modinfo -F vermagic "$ORIGINAL")" ]]
if [[ ! -f "$STATE/spi-tegra114.vendor.ko" ]]; then
    cp -p "$ORIGINAL" "$STATE/spi-tegra114.vendor.ko"
fi
install -D -m 0644 "$BUILD/spi-tegra114.ko" "$TARGET"
depmod -a "$KERNEL"
[[ $(modinfo -n spi_tegra114) == "$TARGET" ]]
install -m 0755 "$DIR/zephyr_j401_can_prepare.sh" /etc/systemd/zephyr_j401_can_prepare.sh
install -m 0644 "$DIR/zephyr-j401-can1-transceiver.service" /etc/systemd/system/
if [[ -f /etc/systemd/zephyr_device_setup.sh && ! -f "$STATE/zephyr_device_setup.sh.before" ]]; then
    cp -p /etc/systemd/zephyr_device_setup.sh "$STATE/zephyr_device_setup.sh.before"
fi
install -m 0755 "$DIR/zephyr_device_setup.sh" /etc/systemd/zephyr_device_setup.sh
install -m 0644 "$DIR/zephyr_device_setup.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable zephyr_device_setup.service
# Do not start standby service here: a diagnostic gpioset may own GPIO 4.
# The device setup script starts it at boot, before bringing CAN1 up.
echo 'Installed for next boot: CAN0 500 kbps (Ranger), CAN1 1 Mbps (RS arm). No CAN frames sent.'
echo 'Verify after reboot: ip -s -d link show can1; timeout 10 candump can1'
