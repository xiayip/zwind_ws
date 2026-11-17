#!/usr/bin/env bash
# Save GNOME's Settings > Power > Screen Blank = Never for the desktop user.
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
  # Persist the setting even when setting up over SSH before a desktop login.
  settings_cmd=(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR
    GSETTINGS_BACKEND=dconf dbus-run-session -- gsettings)
fi

"${settings_cmd[@]}" set org.gnome.desktop.session idle-delay 0
actual="$("${settings_cmd[@]}" get org.gnome.desktop.session idle-delay)"
if [[ "$actual" != 'uint32 0' ]]; then
  echo "Failed to save Screen Blank = Never: $actual" >&2
  exit 1
fi
echo "[display] Screen Blank = Never saved for $(id -un) (idle-delay=0)."
