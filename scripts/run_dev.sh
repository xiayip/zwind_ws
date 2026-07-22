#!/bin/bash
# ==================================================================================================
# run_dev.sh — Launch the Zephyr development container
#
# Usage:
#   ./scripts/run_dev.sh                  # build image, then run
#   ./scripts/run_dev.sh -b               # skip build (image must already exist)
#   ./scripts/run_dev.sh -d /path/to/ws   # override workspace mount path
# ==================================================================================================
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WS_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"

source "${SCRIPT_DIR}/print_color.sh"

# --------------- Defaults ------------------------------------------------------------------------
ZEPHYR_DEV_DIR="${ZEPHYR_WS:-$(cd "${WS_DIR}/.." && pwd)}"
SKIP_IMAGE_BUILD=0
VERBOSE=0
DOCKER_ARGS=()
ZEPHYR_CONTAINER_WS_DIR="/workspaces/zephyr-dev"

# --------------- Parse arguments -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--zephyr_dev_dir)   ZEPHYR_DEV_DIR="$2"; shift 2 ;;
        -b|--skip_image_build)  SKIP_IMAGE_BUILD=1; shift ;;
        -a|--docker_arg)        DOCKER_ARGS+=("$2"); shift 2 ;;
        -v|--verbose)           VERBOSE=1; shift ;;
        -h|--help)
            echo "Usage: $0 [-d workspace_dir] [-b] [-a docker_arg] [-v]"
            exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Keep Codex IDE/CLI state outside the disposable container. The container is
# launched with --rm, so anything stored only under /home/admin would otherwise
# be deleted when the container exits. Override CODEX_STATE_DIR when a different
# persistent host location is preferred.
CODEX_STATE_DIR="${CODEX_STATE_DIR:-${ZEPHYR_DEV_DIR}/.codex-container}"

# --------------- Validations ---------------------------------------------------------------------
if [[ ! -d "$ZEPHYR_DEV_DIR" ]]; then
    print_error "Workspace directory does not exist: $ZEPHYR_DEV_DIR"
    exit 1
fi

if [[ -e "$CODEX_STATE_DIR" && ! -d "$CODEX_STATE_DIR" ]]; then
    print_error "Codex state path exists but is not a directory: $CODEX_STATE_DIR"
    exit 1
fi

mkdir -p "$CODEX_STATE_DIR"
chmod 700 "$CODEX_STATE_DIR"

if [[ $(id -u) -eq 0 ]]; then
    print_error "Do not run this script as root. Add yourself to the docker group instead."
    exit 1
fi

source "${SCRIPT_DIR}/ensure_docker.sh"

if ! docker ps >/dev/null 2>&1; then
    print_error "Unable to run docker commands. Check your Docker installation."
    exit 1
fi

# --------------- Detect platform -----------------------------------------------------------------
PLATFORM="$(uname -m)"
BASE_NAME="zephyr_dev_24.04-${PLATFORM}:latest"
CONTAINER_NAME="zephyr_dev_24.04-${PLATFORM}-container"

# --------------- Reuse / attach to existing container --------------------------------------------
# Remove exited containers with the same name
if [ "$(docker ps -a --quiet --filter status=exited --filter name=$CONTAINER_NAME)" ]; then
    docker rm "$CONTAINER_NAME" > /dev/null
fi

# Attach to running container
if [ "$(docker ps -a --quiet --filter status=running --filter name=$CONTAINER_NAME)" ]; then
    print_info "Attaching to running container: $CONTAINER_NAME"
    ZEPHYR_WS=$(docker exec "$CONTAINER_NAME" printenv ZEPHYR_WS)
    docker exec -it -u admin --workdir "$ZEPHYR_WS" "$CONTAINER_NAME" /bin/bash
    exit 0
fi

# --------------- Build image (unless skipped) ----------------------------------------------------
if [[ $SKIP_IMAGE_BUILD -ne 1 ]]; then
    print_info "Building image: $BASE_NAME"
    "${SCRIPT_DIR}/build_image.sh"
    if [[ $? -ne 0 ]]; then
        if [[ -z $(docker image ls --quiet "$BASE_NAME") ]]; then
            print_error "Build failed and no cached image found for $BASE_NAME. Aborting."
            exit 1
        else
            print_warning "Build failed but a cached image exists — using it."
        fi
    fi
fi

# Check image exists
if [[ -z $(docker image ls --quiet "$BASE_NAME") ]]; then
    print_error "No image found for $BASE_NAME. Run without -b to build first."
    exit 1
fi

# --------------- Docker run arguments ------------------------------------------------------------
# Display / GPU
DOCKER_ARGS+=("-v /tmp/.X11-unix:/tmp/.X11-unix")
DOCKER_ARGS+=("-v $HOME/.Xauthority:/home/admin/.Xauthority:rw")
DOCKER_ARGS+=("-e DISPLAY")
DOCKER_ARGS+=("-e NVIDIA_VISIBLE_DEVICES=all")
DOCKER_ARGS+=("-e NVIDIA_DRIVER_CAPABILITIES=all")
DOCKER_ARGS+=("-e ROS_DOMAIN_ID")
DOCKER_ARGS+=("-e USER")
DOCKER_ARGS+=("-e ZEPHYR_WS=${ZEPHYR_CONTAINER_WS_DIR}")
DOCKER_ARGS+=("-e HOST_USER_UID=$(id -u)")
DOCKER_ARGS+=("-e HOST_USER_GID=$(id -g)")

# Codex stores IDE/CLI history, configuration, and other local state here.
DOCKER_ARGS+=("-v $CODEX_STATE_DIR:/home/admin/.codex")

# SSH agent forwarding
if [[ -n "$SSH_AUTH_SOCK" ]]; then
    DOCKER_ARGS+=("-v $SSH_AUTH_SOCK:/ssh-agent")
    DOCKER_ARGS+=("-e SSH_AUTH_SOCK=/ssh-agent")
fi

# SSH keys (read-only)
if [[ -d "$HOME/.ssh" ]]; then
    DOCKER_ARGS+=("-v $HOME/.ssh:/home/admin/.ssh:ro")
fi

# Robot environment file
ROBOT_ENV_FILE="/etc/zephyr/robot.env"
if [[ -f "$ROBOT_ENV_FILE" ]]; then
    DOCKER_ARGS+=("--env-file $ROBOT_ENV_FILE")
else
    print_warning "Robot environment file not found: $ROBOT_ENV_FILE (skipping --env-file)"
fi

# Platform-specific mounts (Jetson / aarch64)
if [[ "$PLATFORM" == "aarch64" ]]; then
    DOCKER_ARGS+=("-e NVIDIA_VISIBLE_DEVICES=nvidia.com/gpu=all")
    DOCKER_ARGS+=("-v /usr/bin/tegrastats:/usr/bin/tegrastats")
    DOCKER_ARGS+=("-v /tmp/:/tmp/")
    DOCKER_ARGS+=("-v /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra")
    DOCKER_ARGS+=("-v /usr/src/jetson_multimedia_api:/usr/src/jetson_multimedia_api")
    DOCKER_ARGS+=("--pid=host")
    DOCKER_ARGS+=("-v /usr/share/vpi4:/usr/share/vpi4")
    DOCKER_ARGS+=("-v /dev/input:/dev/input")
    # jtop socket
    if [[ $(getent group jtop) ]]; then
        DOCKER_ARGS+=("-v /run/jtop.sock:/run/jtop.sock:ro")
    fi
fi

# Load extra docker args from file (same convention as before)
DOCKER_ARGS_FILE="${WS_DIR}/docker/.dockerargs"
if [[ -f "$DOCKER_ARGS_FILE" ]]; then
    print_info "Loading extra Docker args from $DOCKER_ARGS_FILE"
    readarray -t EXTRA_ARGS < "$DOCKER_ARGS_FILE"
    for arg in "${EXTRA_ARGS[@]}"; do
        DOCKER_ARGS+=($(eval "echo $arg | envsubst"))
    done
fi

# --------------- Launch container ----------------------------------------------------------------
print_info "Running container: $CONTAINER_NAME"
if [[ $VERBOSE -eq 1 ]]; then set -x; fi

docker run -it --rm \
    --privileged \
    --network host \
    --ipc=host \
    ${DOCKER_ARGS[@]} \
    -v /dev:/dev \
    -v "$ZEPHYR_DEV_DIR":"$ZEPHYR_CONTAINER_WS_DIR" \
    -v /etc/localtime:/etc/localtime:ro \
    --name "$CONTAINER_NAME" \
    --runtime nvidia \
    --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
    --workdir "$ZEPHYR_CONTAINER_WS_DIR" \
    "$BASE_NAME" \
    /bin/bash
