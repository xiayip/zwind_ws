#!/bin/bash
# ==================================================================================================
# build_image.sh — Build the Docker image stack for Zephyr development (aarch64 / Jetson)
#
# Build chain (3 layers, built bottom-up — each layer's output is the next layer's BASE_IMAGE):
#   1. Dockerfile.base         — Platform base (Ubuntu 24.04 noble, CUDA 13, TensorRT, VPI4, Triton)
#   2. Dockerfile.ros2_jazzy   — ROS 2 Jazzy + MoveIt 2
#   3. Dockerfile.zephyr       — Zephyr robot-specific packages
#
# Usage:
#   ./scripts/build_image.sh [--no-cache]
# ==================================================================================================
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WS_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
DOCKER_DIR="${WS_DIR}/docker"

source "${SCRIPT_DIR}/print_color.sh"

# --------------- Arguments -----------------------------------------------------------------------
NO_CACHE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache) NO_CACHE="--no-cache"; shift ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# --------------- Detect platform -----------------------------------------------------------------
PLATFORM="$(uname -m)"
if [[ "$PLATFORM" != "aarch64" ]]; then
    print_error "This image stack only supports aarch64 (Jetson). Detected: $PLATFORM"
    exit 1
fi

ZEPHYR_DOCKER_REQUIRE_NVIDIA="${ZEPHYR_DOCKER_REQUIRE_NVIDIA:-0}"
export ZEPHYR_DOCKER_REQUIRE_NVIDIA
source "${SCRIPT_DIR}/ensure_docker.sh"

FINAL_IMAGE="zephyr_dev_24.04-${PLATFORM}:latest"
BASE_LAYER_IMAGE="${ZEPHYR_BASE_LAYER_IMAGE:-zephyr-base-image}"
ROS_LAYER_IMAGE="${ZEPHYR_ROS_LAYER_IMAGE:-zephyr-ros2-jazzy-image}"
ROBOT_DOCKERFILE="${ZEPHYR_ROBOT_DOCKERFILE:-Dockerfile.zephyr}"

BUILD_ARGS=("--build-arg" "USERNAME=admin")

# --------------- Define layers -------------------------------------------------------------------
# Each entry: <dockerfile> <image_tag>
DOCKERFILES=(
    "Dockerfile.base"
    "Dockerfile.ros2_jazzy"
    "$ROBOT_DOCKERFILE"
)
IMAGE_TAGS=(
    "$BASE_LAYER_IMAGE"
    "$ROS_LAYER_IMAGE"
    "${FINAL_IMAGE}"
)

# --------------- Build layers sequentially -------------------------------------------------------
PREV_IMAGE=""
for (( i=0; i<${#DOCKERFILES[@]}; i++ )); do
    DOCKERFILE="${DOCKERFILES[i]}"
    IMAGE_TAG="${IMAGE_TAGS[i]}"
    DOCKERFILE_PATH="${DOCKER_DIR}/${DOCKERFILE}"

    if [[ ! -f "$DOCKERFILE_PATH" ]]; then
        print_error "Dockerfile not found: ${DOCKERFILE_PATH}"
        exit 1
    fi

    BASE_IMAGE_ARG=""
    if [[ -n "$PREV_IMAGE" ]]; then
        BASE_IMAGE_ARG="--build-arg BASE_IMAGE=${PREV_IMAGE}"
    fi

    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Building layer ($((i+1))/${#DOCKERFILES[@]}): ${DOCKERFILE}  →  ${IMAGE_TAG}"
    [[ -n "$PREV_IMAGE" ]] && print_info "  base image : ${PREV_IMAGE}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    DOCKER_BUILDKIT=1 docker build \
        -f "${DOCKERFILE_PATH}" \
        --network host \
        -t "${IMAGE_TAG}" \
        ${BASE_IMAGE_ARG} \
        "${BUILD_ARGS[@]}" \
        ${NO_CACHE} \
        "${DOCKER_DIR}"

    PREV_IMAGE="${IMAGE_TAG}"
done

print_info ""
print_info "✅  Image ready: ${FINAL_IMAGE}"
