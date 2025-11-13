#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run this script as root (e.g. sudo $0)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="/etc/systemd/network"
UDEV_DIR="/etc/udev/rules.d"
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_SCRIPT_DIR="/etc/systemd"

log() {
  echo "[setup] $*"
}

write_file_if_needed() {
  local target="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    log "Unchanged $target"
  else
    install -D -m 0644 "$tmp" "$target"
    log "Installed $target"
  fi
  rm -f "$tmp"
}

copy_file_if_needed() {
  local source="$1"
  local mode="$2"
  local destination="$3"
  if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
    log "Unchanged $destination"
  else
    install -D -m "$mode" "$source" "$destination"
    log "Installed $destination"
  fi
}

ensure_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' not found in PATH" >&2
    exit 1
  fi
}

ensure_binary udevadm
ensure_binary systemctl
ensure_binary install

log "Configuring systemd network link files"
mkdir -p "$NETWORK_DIR"

MTTCAN_LINK_CONTENT="$(cat <<'EOF'
[Match]
Driver=mttcan

[Link]
Name=can0
EOF
)"
write_file_if_needed "$NETWORK_DIR/10-mttcan.link" "$MTTCAN_LINK_CONTENT"

GSUSB_LINK_CONTENT="$(cat <<'EOF'
[Match]
Driver=gs_usb

[Link]
Name=can1
EOF
)"
write_file_if_needed "$NETWORK_DIR/20-gsusb.link" "$GSUSB_LINK_CONTENT"

log "Installing udev rules"
mkdir -p "$UDEV_DIR"
copy_file_if_needed "$SCRIPT_DIR/80-can-names.rules" 0644 "$UDEV_DIR/80-can-names.rules"
copy_file_if_needed "$SCRIPT_DIR/99-obsensor-libusb.rules" 0644 "$UDEV_DIR/99-obsensor-libusb.rules"
copy_file_if_needed "$SCRIPT_DIR/99-odin-usb.rules" 0644 "$UDEV_DIR/99-odin-usb.rules"

log "Installing zwind device setup service files"
mkdir -p "$SYSTEMD_SCRIPT_DIR"
copy_file_if_needed "$SCRIPT_DIR/zwind_device_setup.sh" 0755 "$SYSTEMD_SCRIPT_DIR/zwind_device_setup.sh"
mkdir -p "$SYSTEMD_DIR"
copy_file_if_needed "$SCRIPT_DIR/zwind_device_setup.service" 0644 "$SYSTEMD_DIR/zwind_device_setup.service"

log "Reloading systemd and udev"
systemctl daemon-reload
systemctl enable zwind_device_setup

udevadm control --reload-rules
udevadm trigger --type=devices --action=add

nvidia-ctk cdi generate --mode=csv --output=/etc/cdi/nvidia.yaml

log "You may need to install gs_usb kernel module if not already installed. "
log "Check: https://github.com/lucianovk/jetson-gs_usb-kernel-builder"

log "Setup complete"
