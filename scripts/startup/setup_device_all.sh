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
DEVICE_SETUP_SERVICE_NAME="${ZEPHYR_DEVICE_SETUP_SERVICE_NAME:-zephyr_device_setup}"
DEVICE_SETUP_SCRIPT="${DEVICE_SETUP_SERVICE_NAME}.sh"
DEVICE_SETUP_SERVICE="${DEVICE_SETUP_SERVICE_NAME}.service"

log() {
  echo "[setup] $*"
}

write_file_if_needed() {
  local target="$1"
  local content="$2"
  if [[ -f "$target" ]]; then
    log "Skipping existing $target"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"
  install -D -m 0644 "$tmp" "$target"
  log "Installed $target"
  rm -f "$tmp"
}

copy_file_if_needed() {
  local source="$1"
  local mode="$2"
  local destination="$3"
  if [[ -f "$destination" ]]; then
    log "Skipping existing $destination"
    return
  fi
  install -D -m "$mode" "$source" "$destination"
  log "Installed $destination"
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

log "Installing device setup service files: $DEVICE_SETUP_SERVICE_NAME"
mkdir -p "$SYSTEMD_SCRIPT_DIR"
copy_file_if_needed "$SCRIPT_DIR/$DEVICE_SETUP_SCRIPT" 0755 "$SYSTEMD_SCRIPT_DIR/$DEVICE_SETUP_SCRIPT"
mkdir -p "$SYSTEMD_DIR"
copy_file_if_needed "$SCRIPT_DIR/$DEVICE_SETUP_SERVICE" 0644 "$SYSTEMD_DIR/$DEVICE_SETUP_SERVICE"

log "Reloading systemd and udev"
systemctl daemon-reload
systemctl enable "$DEVICE_SETUP_SERVICE_NAME"

udevadm control --reload-rules
udevadm trigger --type=devices --action=add

nvidia-ctk cdi generate --mode=csv --output=/etc/cdi/nvidia.yaml

log "You may need to install gs_usb kernel module if not already installed. "
log "Run: $SCRIPT_DIR/install_gs_usb.sh"

log "Setup complete"
