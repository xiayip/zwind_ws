#!/bin/bash
# ==================================================================================================
# run_dev.sh — Launch the zwind Isaac ROS development container
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
ISAAC_ROS_DEV_DIR="${ISAAC_ROS_WS:-$(cd "${WS_DIR}/.." && pwd)}"
SKIP_IMAGE_BUILD=0
VERBOSE=0
DOCKER_ARGS=()

# --------------- Parse arguments -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--isaac_ros_dev_dir) ISAAC_ROS_DEV_DIR="$2"; shift 2 ;;
        -b|--skip_image_build)  SKIP_IMAGE_BUILD=1; shift ;;
        -a|--docker_arg)        DOCKER_ARGS+=("$2"); shift 2 ;;
        -v|--verbose)           VERBOSE=1; shift ;;
        -h|--help)
            echo "Usage: $0 [-d workspace_dir] [-b] [-a docker_arg] [-v]"
            exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# --------------- Validations ---------------------------------------------------------------------
if [[ ! -d "$ISAAC_ROS_DEV_DIR" ]]; then
    print_error "Workspace directory does not exist: $ISAAC_ROS_DEV_DIR"
    exit 1
fi

if [[ $(id -u) -eq 0 ]]; then
    print_error "Do not run this script as root. Add yourself to the docker group instead."
    exit 1
fi

RE="\<docker\>"
if [[ ! $(groups "$USER") =~ $RE ]]; then
    print_error "User |$USER| is not in the 'docker' group."
    print_error "Run: sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi

if [[ -z "$(docker ps 2>/dev/null)" ]]; then
    print_error "Unable to run docker commands. Check your Docker installation."
    exit 1
fi

# --------------- Detect platform -----------------------------------------------------------------
PLATFORM="$(uname -m)"
BASE_NAME="isaac_ros_dev-${PLATFORM}"
CONTAINER_NAME="${BASE_NAME}-container"

# --------------- Reuse / attach to existing container --------------------------------------------
# Remove exited containers with the same name
if [ "$(docker ps -a --quiet --filter status=exited --filter name=$CONTAINER_NAME)" ]; then
    docker rm "$CONTAINER_NAME" > /dev/null
fi

# Attach to running container
if [ "$(docker ps -a --quiet --filter status=running --filter name=$CONTAINER_NAME)" ]; then
    print_info "Attaching to running container: $CONTAINER_NAME"
    ISAAC_ROS_WS=$(docker exec "$CONTAINER_NAME" printenv ISAAC_ROS_WS)
    docker exec -it -u admin --workdir "$ISAAC_ROS_WS" "$CONTAINER_NAME" /bin/bash
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
DOCKER_ARGS+=("-e ISAAC_ROS_WS=/workspaces/isaac_ros-dev")
DOCKER_ARGS+=("-e HOST_USER_UID=$(id -u)")
DOCKER_ARGS+=("-e HOST_USER_GID=$(id -g)")

# SSH agent forwarding
if [[ -n "$SSH_AUTH_SOCK" ]]; then
    DOCKER_ARGS+=("-v $SSH_AUTH_SOCK:/ssh-agent")
    DOCKER_ARGS+=("-e SSH_AUTH_SOCK=/ssh-agent")
fi

# Platform-specific mounts (Jetson / aarch64)
if [[ "$PLATFORM" == "aarch64" ]]; then
    DOCKER_ARGS+=("-e NVIDIA_VISIBLE_DEVICES=nvidia.com/gpu=all,nvidia.com/pva=all")
    DOCKER_ARGS+=("-v /usr/bin/tegrastats:/usr/bin/tegrastats")
    DOCKER_ARGS+=("-v /tmp/:/tmp/")
    DOCKER_ARGS+=("-v /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra")
    DOCKER_ARGS+=("-v /usr/src/jetson_multimedia_api:/usr/src/jetson_multimedia_api")
    DOCKER_ARGS+=("--pid=host")
    DOCKER_ARGS+=("-v /usr/share/vpi3:/usr/share/vpi3")
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
    -v "$ISAAC_ROS_DEV_DIR":/workspaces/isaac_ros-dev \
    -v /etc/localtime:/etc/localtime:ro \
    --name "$CONTAINER_NAME" \
    --runtime nvidia \
    --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
    --workdir /workspaces/isaac_ros-dev \
    "$BASE_NAME" \
    /bin/bash
