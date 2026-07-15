#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_RESET='\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

STEP_TOTAL=4
STEP_CURRENT=0
CURRENT_STEP_NAME=""

step() {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    CURRENT_STEP_NAME="$1"
    echo -e "\n${C_BLUE}==> [${STEP_CURRENT}/${STEP_TOTAL}] ${CURRENT_STEP_NAME}${C_RESET}"
}

ok()   { echo -e "${C_GREEN}    ✔ $*${C_RESET}"; }
skip() { echo -e "${C_YELLOW}    ↷ $* (already done, skipping)${C_RESET}"; }
fail() { echo -e "${C_RED}    ✘ Step failed: ${CURRENT_STEP_NAME}${C_RESET}" >&2; }
trap 'fail' ERR

# ---------------------------------------------------------------------------
# Step 1: Install required tools
# ---------------------------------------------------------------------------
step "Checking required tools (vcstool, git-lfs)"

APT_PACKAGES=()

if ! command -v vcs &> /dev/null; then
    echo "    vcs not found, will install vcstool"
    APT_PACKAGES+=(vcstool)
fi

if ! command -v git-lfs &> /dev/null; then
    echo "    git-lfs not found, will install git-lfs"
    APT_PACKAGES+=(git-lfs)
fi

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
    ok "Installed: ${APT_PACKAGES[*]}"
else
    skip "All required tools present"
fi

# ---------------------------------------------------------------------------
# Step 2: Import source repositories
# ---------------------------------------------------------------------------
step "Importing source repositories (vcs import)"

vcs import < dev.repos --skip-existing --repos --debug
ok "Repositories are up to date"

# ---------------------------------------------------------------------------
# Step 3: Set up device configuration (udev rules, systemd services, etc.)
# ---------------------------------------------------------------------------
step "Setting up device configuration (udev rules, systemd services)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo "$SCRIPT_DIR/scripts/startup/setup_device_all.sh"
ok "Device configuration complete"

# ---------------------------------------------------------------------------
# Step 4: Set up Tailscale
# ---------------------------------------------------------------------------
step "Setting up Tailscale"

ROBOT_ENV_FILE="/etc/zephyr/robot.env"
if ! sudo test -f "$ROBOT_ENV_FILE"; then
    echo -e "${C_RED}    ✘ Missing $ROBOT_ENV_FILE (required for TAILSCALE_AUTH_KEY / TAILSCALE_HOSTNAME)${C_RESET}" >&2
    exit 1
fi

# Load robot env (root-owned, mode 600) into this shell
set -a
source <(sudo cat "$ROBOT_ENV_FILE")
set +a

if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
    echo -e "${C_RED}    ✘ TAILSCALE_AUTH_KEY is not set in $ROBOT_ENV_FILE${C_RESET}" >&2
    exit 1
fi
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-${ROBOT_ID:-$(hostname)}}"

if command -v tailscale &> /dev/null; then
    skip "tailscale already installed ($(tailscale version | head -n1))"
else
    echo "    Installing tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Installed tailscale"
fi

sudo systemctl enable --now tailscaled

if [[ "$(tailscale status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -n1)" == *'"Running"'* ]]; then
    skip "tailscale already connected as '$(tailscale status --json | grep -o '"HostName": *"[^"]*"' | head -n1 | cut -d'"' -f4)'"
else
    echo "    Connecting to tailscale as '$TAILSCALE_HOSTNAME'..."
    sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="$TAILSCALE_HOSTNAME"
    ok "Tailscale connected as '$TAILSCALE_HOSTNAME'"
fi

echo -e "\n${C_GREEN}All ${STEP_TOTAL} steps completed successfully.${C_RESET}"
