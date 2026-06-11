#!/bin/bash
# Ensure Docker is installed, running, and usable by the current script.
set -e

if [[ "${ZWIND_DOCKER_USE_SUDO:-0}" == "1" ]]; then
    function docker {
        if [[ -n "${DOCKER_BUILDKIT+x}" ]]; then
            sudo env DOCKER_BUILDKIT="$DOCKER_BUILDKIT" "${ZWIND_DOCKER_BIN:-docker}" "$@"
        else
            sudo "${ZWIND_DOCKER_BIN:-docker}" "$@"
        fi
    }
    export -f docker
fi

if [[ "${ZWIND_DOCKER_READY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ZWIND_DOCKER_READY=1

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

    ZWIND_DOCKER_BIN="$(command -v docker)"
    export ZWIND_DOCKER_BIN
    export ZWIND_DOCKER_USE_SUDO=1

    function docker {
        if [[ -n "${DOCKER_BUILDKIT+x}" ]]; then
            sudo env DOCKER_BUILDKIT="$DOCKER_BUILDKIT" "$ZWIND_DOCKER_BIN" "$@"
        else
            sudo "$ZWIND_DOCKER_BIN" "$@"
        fi
    }
    export -f docker
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