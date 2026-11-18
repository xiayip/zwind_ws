#!/usr/bin/env bash
# Run as the Jetson desktop user on the host, not inside the ROS container.
set -euo pipefail

if [[ $EUID -eq 0 || -f /.dockerenv ]]; then
  echo "Run as the normal desktop user on the host (without sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HMI_SCRIPTS="$SCRIPT_DIR/../../src/zephyr_interaction/zephyr_hmi/scripts"
if [[ ! -f "$HMI_SCRIPTS/configure-kiosk-autostart.py" || ! -f "$HMI_SCRIPTS/run-kiosk.sh" ||
      ! -f "$HMI_SCRIPTS/ensure-kiosk-fullscreen.py" || ! -f "$HMI_SCRIPTS/configure-kiosk-lock.py" ]]; then
  echo "Missing zephyr_hmi source. Import dev.repos before setting up the HMI browser." >&2
  exit 1
fi

packages=()
for entry in curl:curl flock:util-linux xrandr:x11-xserver-utils xprop:x11-utils /usr/bin/python3:python3 gjs:gjs; do
  command -v "${entry%%:*}" >/dev/null || packages+=("${entry#*:}")
done
if ! /usr/bin/python3 -c "import gi; gi.require_version('GdkX11', '3.0'); from gi.repository import GdkX11" 2>/dev/null; then
  packages+=(python3-gi gir1.2-gtk-3.0)
fi
if ! /usr/bin/python3 -c "import gi; gi.require_version('Soup', '3.0'); from gi.repository import Soup" 2>/dev/null; then
  packages+=(gir1.2-soup-3.0)
fi
if [[ -f "$HMI_SCRIPTS/host-network-status.py" ]] && ! /usr/bin/python3 -c 'import dbus' 2>/dev/null; then
  packages+=(python3-dbus)
fi
if ((${#packages[@]})); then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${packages[@]}"
fi

# Ubuntu's browser transition packages can exist without the actual Snap.
browser_available=false
for candidate in chromium chromium-browser google-chrome google-chrome-stable /snap/bin/chromium; do
  if command -v "$candidate" >/dev/null 2>&1 && \
     version="$(timeout 30 "$candidate" --version 2>/dev/null)" && \
     [[ "$version" == *Chromium* || "$version" == *'Google Chrome'* ]]; then
    browser_available=true
    break
  fi
done
if [[ "$browser_available" == false ]]; then
  if ! command -v snap >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends snapd
  fi
  echo "[hmi] Installing Chromium on the host (sudo authentication may be required)."
  sudo snap install chromium
  /snap/bin/chromium --version
fi

# SSH and app terminals may lack DISPLAY even while the same user is logged in.
# Import only graphical-session fields, without evaluating shell text.
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|DBUS_SESSION_BUS_ADDRESS)
        export "$key=$value" ;;
    esac
  done < <(systemctl --user show-environment 2>/dev/null || true)
fi

/usr/bin/python3 "$HMI_SCRIPTS/configure-kiosk-lock.py"
/usr/bin/python3 "$HMI_SCRIPTS/configure-kiosk-autostart.py" --output auto
if [[ -f "$HMI_SCRIPTS/host-network-status.py" ]]; then
  /usr/bin/python3 "$HMI_SCRIPTS/host-network-status.py" --install
else
  echo "[hmi] Network sampler is unavailable; update zephyr_hmi and rerun this step to enable Wi-Fi/5G readings."
fi

if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  echo "[hmi] No desktop session is active. The browser will wait for HMI at the next desktop login."
  exit 0
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/zephyr-courier-kiosk"
mkdir -p "$state_dir"
lock_file="$state_dir/browser/launcher.lock"
if [[ -f "$lock_file" ]] && ! flock -n "$lock_file" true; then
  echo "[hmi] The fullscreen launcher is already running."
  exit 0
fi
log_file="$state_dir/launcher.log"
nohup bash "$HMI_SCRIPTS/run-kiosk.sh" --wait 0 >>"$log_file" 2>&1 </dev/null &
launcher_pid=$!
sleep 1
if ! kill -0 "$launcher_pid" 2>/dev/null; then
  echo "[hmi] The launcher exited; inspect $log_file" >&2
  tail -20 "$log_file" >&2
  exit 1
fi
echo "[hmi] Fullscreen launcher started; it opens when http://127.0.0.1:8765/ is ready."
echo "[hmi] Log: $log_file; use the screen's password exit button to return to the desktop."
