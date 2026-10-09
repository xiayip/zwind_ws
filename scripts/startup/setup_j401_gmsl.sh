#!/usr/bin/env bash
# Run on the J401 host as root. Does not reboot automatically.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo'; exit 1; }
[[ $(uname -r) == 6.8.12-1021-tegra ]] || { echo 'Untested kernel'; exit 1; }
grep -q 'R39.*REVISION: 2.0' /etc/nv_tegra_release
tr '\0' '\n' < /proc/device-tree/compatible | grep -qx 'nvidia,p3767-0000'
backup=/var/backups/j401-gmsl/stock-3g
overlay=/boot/tegra234-seeed-gmsl1x4-3g-overlay.dtbo
expected=e74b82143ff74e4c1ea161c7aa4b03c49d1a5724b973109ba883b80433b3ccc5
[[ $(sha256sum "$overlay" | cut -d' ' -f1) == "$expected" ]] || {
  echo 'Overlay differs from the validated BSP; inspect before deployment.'; exit 1;
}
if [[ -e "$backup/complete" ]] && grep -qx 'DEFAULT JetsonIO' /boot/extlinux/extlinux.conf \
  && grep -q "OVERLAYS $overlay" /boot/extlinux/extlinux.conf; then
  echo "Already configured; backup: $backup"
  exit 0
fi
mkdir -p "$backup"
exec > >(tee -a "$backup/install.log") 2>&1
date -Is
test -f "$backup/extlinux.conf" || cp -a /boot/extlinux/extlinux.conf "$backup/extlinux.conf"
test -f "$backup/packages.before" || dpkg-query -W > "$backup/packages.before"
test -f "$backup/live-before.dts" || dtc -I fs -O dts /proc/device-tree > "$backup/live-before.dts" 2>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends v4l-utils
/opt/nvidia/jetson-io/config-by-hardware.py -n '2=Seeed GMSL 1X4 3G'
cp -a /boot/extlinux/extlinux.conf "$backup/extlinux.after.conf"
diff -u "$backup/extlinux.conf" /boot/extlinux/extlinux.conf || true
dpkg-query -W > "$backup/packages.after"
touch "$backup/complete"
echo "Configured. Original boot configuration: $backup/extlinux.conf"
