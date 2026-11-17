#!/usr/bin/env bash
# Ubuntu 24.04 / GNOME 46 on Jetson: Waveshare 8.9-inch 600x1600 LCD.
# Save defaults for the next login/boot; do not restart the desktop or GDM.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0 [desktop-user]" >&2
  exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root || "$TARGET_USER" == gdm ]]; then
  echo "Specify the normal desktop user (e.g. sudo bash $0 nvidia)." >&2
  exit 1
fi

for tool in python3 gsettings dbus-run-session runuser getent; do
  command -v "$tool" >/dev/null || { echo "Required command not found: $tool" >&2; exit 1; }
done
for account in "$TARGET_USER" gdm; do
  getent passwd "$account" >/dev/null || { echo "Required account not found: $account" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_XML="$(cat "$SCRIPT_DIR/waveshare-monitors.xml")"
TOUCH_SCHEMA='org.gnome.desktop.peripherals.touchscreen:/org/gnome/desktop/peripherals/touchscreens/0712:000a/'
# The unusual product spelling is the actual EDID, not a typo.
TOUCH_OUTPUT="['HLT', 'WaveShsare089', '0x00000001']"
gsettings list-keys "$TOUCH_SCHEMA" >/dev/null

for account in "$TARGET_USER" gdm; do
  account_home="$(getent passwd "$account" | cut -d: -f6)"
  account_uid="$(id -u "$account")"
  config_dir="$account_home/.config"
  # Do not inherit the invoking user's dconf paths or session bus under sudo.
  user_env=(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR -u DCONF_PROFILE
    XDG_CONFIG_HOME="$config_dir" GSETTINGS_BACKEND=dconf)

  # Run as the owner so new config directories/files have the correct ownership.
  # Pass the template as text: GDM may not be able to read the workspace path.
  runuser -u "$account" -- "${user_env[@]}" python3 - "$config_dir/monitors.xml" "$MONITOR_XML" <<'PY'
import os
from pathlib import Path
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
desired = ET.fromstring(sys.argv[2]).find("configuration")
fields = ("connector", "vendor", "product", "serial")

def monitor_keys(configuration):
    return sorted(tuple(spec.findtext(field) for field in fields)
                  for spec in configuration.findall(".//monitorspec"))

original = path.read_bytes() if path.exists() else None
parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
root = ET.fromstring(original, parser=parser) if original is not None else ET.Element("monitors", version="2")
if root.tag != "monitors" or root.get("version") != "2":
    raise SystemExit(f"Unsupported monitor configuration: {path}")

# Replace only the single Waveshare layout. Keep other screens/multi-screen layouts.
for configuration in root.findall("configuration"):
    if monitor_keys(configuration) == monitor_keys(desired):
        root.remove(configuration)
root.append(desired)
ET.indent(root, space="  ")
content = ET.tostring(root, encoding="utf-8") + b"\n"
if content != original:
    path.parent.mkdir(parents=True, exist_ok=True)
    backup = path.with_name("monitors.xml.before-waveshare")
    if original is not None and not backup.exists():
        shutil.copy2(path, backup)
    fd, temporary = tempfile.mkstemp(prefix=".monitors-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"[display] Updated {path}")
else:
    print(f"[display] Already configured: {path}")
PY

  # An active desktop bus applies the touch change immediately. A private bus
  # also persists it when installing over SSH or before the first desktop login.
  if [[ -S "/run/user/$account_uid/bus" ]]; then
    session_cmd=(env XDG_RUNTIME_DIR="/run/user/$account_uid"
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$account_uid/bus")
  else
    session_cmd=(dbus-run-session --)
  fi
  runuser -u "$account" -- "${user_env[@]}" "${session_cmd[@]}" \
    gsettings set "$TOUCH_SCHEMA" output "$TOUCH_OUTPUT"
  actual="$(runuser -u "$account" -- "${user_env[@]}" "${session_cmd[@]}" \
    gsettings get "$TOUCH_SCHEMA" output)"
  [[ "$actual" == "$TOUCH_OUTPUT" ]] || { echo "Touch mapping verification failed for $account" >&2; exit 1; }
  echo "[display] Touch mapping saved for $account: $actual"
done

echo "[display] Defaults saved: 1600x600 landscape (right rotation), with matching touch."
echo "[display] Display defaults take effect at the next login/boot; no session was restarted."
