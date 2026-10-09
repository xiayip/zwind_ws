#!/usr/bin/env bash
# For an existing pulled Zephyr dev image. New local builds use Dockerfile.zephyr.
set -euo pipefail
[[ -f /.dockerenv ]] || { echo 'Run inside the Zephyr development container.' >&2; exit 1; }
packages=(v4l-utils ros-jazzy-rclcpp-components ros-jazzy-image-transport
  ros-jazzy-compressed-image-transport ros-jazzy-camera-info-manager libopencv-dev)
missing=()
for package in "${packages[@]}"; do
  if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]]; then
    missing+=("$package")
  fi
done
if (( ${#missing[@]} == 0 )); then
  echo 'GMSL runtime dependencies already installed.'
  exit 0
fi
elevate=()
(( EUID == 0 )) || elevate=(sudo)
"${elevate[@]}" apt-get update
"${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
