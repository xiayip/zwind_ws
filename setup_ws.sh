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
# Step 3: Configure extra docker run arguments
# ---------------------------------------------------------------------------
step "Configuring docker run arguments (docker/.dockerargs)"

DOCKERARGS_FILE="./docker/.dockerargs"
DOCKERARGS_CONTENT="-v $HOME/.ssh:/home/admin/.ssh:ro"

if [[ -f "$DOCKERARGS_FILE" ]] && [[ "$(cat "$DOCKERARGS_FILE")" == "$DOCKERARGS_CONTENT" ]]; then
    skip "$DOCKERARGS_FILE already configured"
else
    printf '%s\n' "$DOCKERARGS_CONTENT" > "$DOCKERARGS_FILE"
    ok "Wrote $DOCKERARGS_FILE"
fi

# ---------------------------------------------------------------------------
# Step 4: Set up device configuration (udev rules, systemd services, etc.)
# ---------------------------------------------------------------------------
step "Setting up device configuration (udev rules, systemd services)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo "$SCRIPT_DIR/scripts/startup/setup_device_all.sh"
ok "Device configuration complete"

echo -e "\n${C_GREEN}All ${STEP_TOTAL} steps completed successfully.${C_RESET}"
