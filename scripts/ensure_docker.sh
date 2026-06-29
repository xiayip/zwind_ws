#!/bin/bash
# Ensure Docker is installed, running, and usable by the current script.
set -e

ZEPHYR_DOCKER_USE_SUDO="${ZEPHYR_DOCKER_USE_SUDO:-0}"
ZEPHYR_DOCKER_READY="${ZEPHYR_DOCKER_READY:-0}"
ZEPHYR_DOCKER_BIN="${ZEPHYR_DOCKER_BIN:-docker}"
ZEPHYR_DOCKER_REQUIRE_NVIDIA="${ZEPHYR_DOCKER_REQUIRE_NVIDIA:-1}"
export ZEPHYR_DOCKER_USE_SUDO ZEPHYR_DOCKER_READY ZEPHYR_DOCKER_BIN ZEPHYR_DOCKER_REQUIRE_NVIDIA

if [[ "$ZEPHYR_DOCKER_USE_SUDO" == "1" ]]; then
    function docker {
        if [[ -n "${DOCKER_BUILDKIT+x}" ]]; then
            sudo env DOCKER_BUILDKIT="$DOCKER_BUILDKIT" "${ZEPHYR_DOCKER_BIN:-docker}" "$@"
        else
            sudo "${ZEPHYR_DOCKER_BIN:-docker}" "$@"
        fi
    }
    export -f docker
fi

if [[ "$ZEPHYR_DOCKER_READY" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ZEPHYR_DOCKER_READY=1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "${SCRIPT_DIR}/print_color.sh"

function install_docker_apt {
    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "Docker is not installed and this system does not have apt-get. Install Docker manually."
        exit 1
    fi

    local docker_os=""
    local codename=""
    local os_id=""
    local os_like=""

    if [[ -r /etc/os-release ]]; then
        source /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
        codename="${VERSION_CODENAME:-}"
    fi

    case "$os_id" in
        ubuntu|debian)
            docker_os="$os_id"
            ;;
        *)
            if [[ "$os_like" == *"ubuntu"* ]]; then
                docker_os="ubuntu"
            elif [[ "$os_like" == *"debian"* ]]; then
                docker_os="debian"
            fi
            ;;
    esac

    if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
        codename="$(lsb_release -cs)"
    fi

    if [[ -z "$docker_os" || -z "$codename" ]]; then
        print_error "Unable to detect a supported apt repository for Docker. Install Docker manually."
        exit 1
    fi

    print_warning "Docker is not installed. Installing Docker from the official Docker apt repository..."
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings

    local keyring="/etc/apt/keyrings/docker.gpg"
    if [[ ! -s "$keyring" ]]; then
        curl -fsSL "https://download.docker.com/linux/${docker_os}/gpg" | sudo gpg --dearmor --yes -o "$keyring"
        sudo chmod a+r "$keyring"
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    echo "deb [arch=${arch} signed-by=${keyring}] https://download.docker.com/linux/${docker_os} ${codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
}

function start_docker_daemon {
    if command docker info >/dev/null 2>&1; then
        return 0
    fi

    print_info "Starting Docker service..."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
        if sudo systemctl enable --now docker; then
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        sudo service docker start || true
    fi
}

function ensure_docker_group {
    if [[ $(id -u) -eq 0 ]]; then
        return 0
    fi

    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
    fi

    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        print_warning "Adding user '$USER' to the docker group for future shells."
        sudo usermod -aG docker "$USER"
        print_warning "After this run, open a new login shell or run 'newgrp docker' to use Docker without sudo."
    fi
}

function enable_sudo_docker_fallback {
    if command docker ps >/dev/null 2>&1; then
        return 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
        return 0
    fi

    print_warning "Docker is installed, but this shell cannot use it directly yet."
    print_warning "Using sudo docker for this run."
    sudo -v

    ZEPHYR_DOCKER_BIN="$(command -v docker)"
    ZEPHYR_DOCKER_USE_SUDO=1
    export ZEPHYR_DOCKER_BIN ZEPHYR_DOCKER_USE_SUDO

    function docker {
        if [[ -n "${DOCKER_BUILDKIT+x}" ]]; then
            sudo env DOCKER_BUILDKIT="$DOCKER_BUILDKIT" "$ZEPHYR_DOCKER_BIN" "$@"
        else
            sudo "$ZEPHYR_DOCKER_BIN" "$@"
        fi
    }
    export -f docker
}

# Ensure the NVIDIA container runtime is installed and registered as Docker's default runtime.
# Required so containers can be launched with `--runtime nvidia` (GPU access on Jetson).
# See: https://docs.nvidia.com/jetson/agx-thor-devkit/user-guide/latest/setup_docker.html
function ensure_nvidia_runtime {
    # Already registered? Nothing to do.
    if docker info 2>/dev/null | grep -qiw nvidia; then
        return 0
    fi

    print_warning "Docker 'nvidia' runtime not found. Configuring the NVIDIA Container Toolkit..."

    # Install nvidia-container-toolkit if nvidia-ctk is missing
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        if ! command -v apt-get >/dev/null 2>&1; then
            print_error "nvidia-container-toolkit is not installed and apt-get is unavailable. Install it manually."
            exit 1
        fi

        print_info "Installing nvidia-container-toolkit from the NVIDIA apt repository..."
        local keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --dearmor --yes -o "$keyring"
        sudo chmod a+r "$keyring"
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed "s#deb https://#deb [signed-by=${keyring}] https://#g" \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
    fi

    # Register the 'nvidia' runtime and set it as Docker's default runtime.
    # nvidia-ctk merges into any existing /etc/docker/daemon.json.
    print_info "Registering the 'nvidia' runtime as Docker's default runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker --set-as-default

    # Restart Docker to apply the new runtime configuration.
    print_info "Restarting the Docker service to apply the runtime configuration..."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
        sudo systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
        sudo service docker restart
    fi

    if ! docker info 2>/dev/null | grep -qiw nvidia; then
        print_error "Configured the NVIDIA runtime but Docker still does not report it. Check /etc/docker/daemon.json and the Docker service."
        exit 1
    fi
    print_info "NVIDIA Docker runtime is configured."
}

# Print /dev paths referenced by a CDI spec that are missing on the host.
function nvidia_cdi_missing_host_devices {
    local cdi_spec="$1"
    [[ -f "$cdi_spec" ]] || return 0

    awk '/path:[[:space:]]*\/dev\// { print $NF }' "$cdi_spec" | sort -u | while read -r device_path; do
        [[ -e "$device_path" ]] || printf '%s\n' "$device_path"
    done
}

# Ensure a CDI spec exposing 'nvidia.com/gpu' exists (Jetson / aarch64).
# run_dev.sh launches the container with `NVIDIA_VISIBLE_DEVICES=nvidia.com/gpu=all`, which the
# runtime resolves via the CDI spec at /etc/cdi/nvidia.yaml. On a fresh Jetson this file may be
# missing, incomplete, or stale, causing "unresolvable CDI devices" / "failed to stat CDI host
# device" errors — regenerate it with nvidia-ctk.
function ensure_nvidia_cdi {
    # Only relevant on Jetson / aarch64
    [[ "$(uname -m)" == "aarch64" ]] || return 0

    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        return 0
    fi

    local cdi_spec="/etc/cdi/nvidia.yaml"
    local missing_devices=""

    missing_devices="$(nvidia_cdi_missing_host_devices "$cdi_spec")"

    # Already resolvable and points only at devices that exist? Nothing to do.
    if nvidia-ctk cdi list 2>/dev/null | grep -qx "nvidia.com/gpu=all"; then
        if [[ -z "$missing_devices" ]]; then
            return 0
        fi

        print_warning "CDI spec references missing host device(s): $(echo "$missing_devices" | paste -sd ',' -)"
        print_warning "Regenerating CDI spec..."
    else
        print_warning "CDI device 'nvidia.com/gpu=all' not found. Generating CDI spec..."
    fi

    sudo mkdir -p /etc/cdi
    sudo nvidia-ctk cdi generate --mode=csv --output="$cdi_spec" >/dev/null 2>&1

    if ! nvidia-ctk cdi list 2>/dev/null | grep -qx "nvidia.com/gpu=all"; then
        print_error "Failed to generate a usable CDI spec at $cdi_spec. Check 'nvidia-ctk cdi generate --mode=csv' output."
        exit 1
    fi

    missing_devices="$(nvidia_cdi_missing_host_devices "$cdi_spec")"
    if [[ -n "$missing_devices" ]]; then
        print_error "Generated CDI spec still references missing host device(s): $(echo "$missing_devices" | paste -sd ',' -)"
        exit 1
    fi
    print_info "CDI spec generated (nvidia.com/gpu=all available)."
}

if ! command -v docker >/dev/null 2>&1; then
    install_docker_apt
fi

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker installation completed, but the docker command is still not available."
    exit 1
fi

start_docker_daemon
ensure_docker_group
enable_sudo_docker_fallback

if ! docker ps >/dev/null 2>&1; then
    print_error "Unable to run docker commands. Check the Docker service and your permissions."
    exit 1
fi

if [[ "$ZEPHYR_DOCKER_REQUIRE_NVIDIA" == "1" ]]; then
    ensure_nvidia_runtime
    ensure_nvidia_cdi
fi