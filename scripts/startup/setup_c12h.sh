#!/usr/bin/env bash
# Install C12H serial permissions; optional staging root permits non-root validation.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DESTDIR=${1:-}
if [[ $# -gt 1 || ( -n $DESTDIR && $DESTDIR != /* ) ]]; then
  echo "Usage: $0 [absolute-staging-root]" >&2
  exit 2
fi
if [[ -z $DESTDIR && $(id -u) -ne 0 ]]; then
  echo "Run with sudo, or provide a staging root for validation." >&2
  exit 1
fi
install -D -m 0644 "$SCRIPT_DIR/99-zephyr-c12h.rules" \
  "$DESTDIR/etc/udev/rules.d/99-zephyr-c12h.rules"
if [[ -z $DESTDIR ]]; then
  udevadm control --reload-rules
  echo "C12H rules apply on the next USB reconnect; existing by-id access remains usable."
fi
echo "C12H serial rule installed. No ROS environment configuration is required."
