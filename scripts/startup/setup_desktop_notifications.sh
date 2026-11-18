#!/usr/bin/env bash
# Keep Ubuntu notification banners off the HMI display.
set -euo pipefail

if [[ $EUID -eq 0 || -f /.dockerenv ]]; then
  echo "Run as the normal desktop user on the host (without sudo)." >&2
  exit 1
fi

desktop_uid="$(id -u)"
if [[ -S "/run/user/$desktop_uid/bus" ]]; then
  settings_cmd=(env GSETTINGS_BACKEND=dconf
    XDG_RUNTIME_DIR="/run/user/$desktop_uid"
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" gsettings)
else
  # Persist settings when provisioning over SSH before a desktop login.
  settings_cmd=(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR
    GSETTINGS_BACKEND=dconf dbus-run-session -- gsettings)
fi

save_setting() {
  local schema="$1" key="$2" value="$3" actual
  "${settings_cmd[@]}" set "$schema" "$key" "$value"
  actual="$("${settings_cmd[@]}" get "$schema" "$key")"
  if [[ "$actual" != "$value" ]]; then
    echo "Failed to save $schema $key: $actual (expected $value)" >&2
    exit 1
  fi
}

save_setting org.gnome.desktop.notifications show-banners false
# GNOME lets critical notifications bypass Do Not Disturb. Disable the disk
# warning source as well as its threshold, including its Baobab application ID.
save_setting org.gnome.settings-daemon.plugins.housekeeping free-percent-notify 0.0
save_setting org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/org-gnome-baobab/ enable false

echo "[desktop] Notification banners and low-disk-space alerts disabled for $(id -un)."
