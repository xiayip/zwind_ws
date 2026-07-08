#!/bin/bash
set -euo pipefail

APT_PACKAGES=()

# check if vcs tool is installed
if ! command -v vcs &> /dev/null; then
    echo "vcs not found, installing vcs..."
    APT_PACKAGES+=(vcstool)
fi

# check if git-lfs is installed
if ! command -v git-lfs &> /dev/null; then
    echo "git-lfs not found, installing git-lfs..."
    APT_PACKAGES+=(git-lfs)
fi

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
fi

vcs import < dev.repos --skip-existing --repos --debug

# Configure extra docker run arguments
cat > ./docker/.dockerargs <<EOF
-v $HOME/.ssh:/home/admin/.ssh:ro
EOF

# Set up device configuration (udev rules, systemd services, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo "$SCRIPT_DIR/scripts/startup/setup_device_all.sh"
