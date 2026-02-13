#!/bin/bash
# ==================================================================================================
# build_image.sh — Build the Docker image stack for zwind development
#
# Build chain (3 layers):
#   1. Dockerfile.<ARCH>       — Platform base (CUDA, Python, system libs)
#   2. Dockerfile.ros2_humble  — ROS 2 Humble + MoveIt
#   3. Dockerfile.zwind        — Zwind-specific packages
#
# Before building, the script checks if NVIDIA publishes a pre-built image on
# nvcr.io/nvidia/isaac/ros that matches the hash of the first N Dockerfiles.
# If found, it pulls that image and skips building those layers.
#
# Usage:
#   ./scripts/build_image.sh [--no-cache] [--skip-registry-check]
# ==================================================================================================
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WS_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
DOCKER_DIR="${WS_DIR}/docker"

source "${SCRIPT_DIR}/print_color.sh"

# --------------- Arguments -----------------------------------------------------------------------
NO_CACHE=""
SKIP_REGISTRY_CHECK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache)              NO_CACHE="--no-cache"; shift ;;
        --skip-registry-check)   SKIP_REGISTRY_CHECK=1; shift ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# --------------- Detect platform -----------------------------------------------------------------
PLATFORM="$(uname -m)"
case "$PLATFORM" in
    x86_64)  ARCH_KEY="x86_64";  BUILD_PLATFORM="amd64" ;;
    aarch64) ARCH_KEY="aarch64"; BUILD_PLATFORM="arm64" ;;
    *) print_error "Unsupported architecture: $PLATFORM"; exit 1 ;;
esac

FINAL_IMAGE="isaac_ros_dev-${PLATFORM}"

# --------------- Check GPU -----------------------------------------------------------------------
BUILD_ARGS=("--build-arg" "USERNAME=admin" "--build-arg" "PLATFORM=${BUILD_PLATFORM}")

if [[ "$PLATFORM" == "x86_64" ]]; then
    GPU_ATTACHED=$(nvidia-smi -a 2>/dev/null | grep "Attached GPUs" || true)
    if [[ -n "$GPU_ATTACHED" ]]; then
        BUILD_ARGS+=("--build-arg" "HAS_GPU=true")
    else
        print_warning "No GPU detected — skipping HAS_GPU build arg"
    fi
fi

# --------------- Define layers -------------------------------------------------------------------
# Each entry: <dockerfile> <image_tag>
# Order matters: built bottom-up, each layer's output is the next layer's BASE_IMAGE.
DOCKERFILES=(
    "Dockerfile.${ARCH_KEY}"
    "Dockerfile.ros2_humble"
    "Dockerfile.zwind"
)
IMAGE_TAGS=(
    "${ARCH_KEY}-image"
    "ros2-humble-image"
    "${FINAL_IMAGE}"
)

BASE_REGISTRY="nvcr.io/nvidia/isaac/ros"

# --------------- Pre-built image check -----------------------------------------------------------
# Replicates the logic from the old build_image_layers.sh:
#   - Hash Dockerfiles from the bottom up (cumulative)
#   - For the largest matching set, check nvcr.io for a pre-built image
#   - If found, pull it and skip building those layers
#
# Example: if Dockerfile.x86_64 + Dockerfile.ros2_humble match a pre-built image,
#          we pull it and only need to build Dockerfile.zwind on top.
SKIP_LAYERS=0  # Number of layers to skip (starting from bottom)

if [[ $SKIP_REGISTRY_CHECK -eq 0 ]]; then
    print_info "Checking for pre-built base images on ${BASE_REGISTRY} ..."

    # Try from the largest set of layers (all except last) down to just the first layer
    MAX_CHECK=$(( ${#DOCKERFILES[@]} - 1 ))  # don't check if ALL layers are pre-built

    for (( n=MAX_CHECK; n>=1; n-- )); do
        # Compute cumulative hash of Dockerfiles 0..n-1
        # IMPORTANT: must cd into directory and use relative filename for md5sum,
        # because md5sum output includes the filename and the remote registry
        # hashes were computed with relative paths.
        HASH_INPUT=$(mktemp)
        IMAGE_KEY_PARTS=()
        for (( j=0; j<n; j++ )); do
            ( cd "${DOCKER_DIR}" && md5sum "${DOCKERFILES[j]}" ) >> "$HASH_INPUT"
            # Convert Dockerfile.x86_64 → x86_64, Dockerfile.ros2_humble → ros2_humble
            SUFFIX="${DOCKERFILES[j]#Dockerfile.}"
            IMAGE_KEY_PARTS+=("${SUFFIX}")
        done
        COMBINED_HASH=$(md5sum "$HASH_INPUT" | cut -d' ' -f1)
        rm -f "$HASH_INPUT"

        # Build the tag matching NVIDIA's convention:
        #   keys joined by '.', then only '.' replaced with '-'  (underscores kept)
        #   e.g. ["x86_64","ros2_humble"] → "x86_64.ros2_humble" → "x86_64-ros2_humble"
        IMAGE_KEY_TAG=$(IFS='.'; echo "${IMAGE_KEY_PARTS[*]}")
        IMAGE_KEY_TAG="${IMAGE_KEY_TAG//./-}"
        PREBUILT_IMAGE="${BASE_REGISTRY}:${IMAGE_KEY_TAG}_${COMBINED_HASH}"

        print_info "  Checking: ${PREBUILT_IMAGE}"
        if docker manifest inspect "${PREBUILT_IMAGE}" >/dev/null 2>&1; then
            print_info "✅ Found pre-built image: ${PREBUILT_IMAGE}"
            docker pull "${PREBUILT_IMAGE}"
            print_info "Finished pulling pre-built image."

            # Tag it as the output of layer n-1 so the next layer can use it as BASE_IMAGE
            docker tag "${PREBUILT_IMAGE}" "${IMAGE_TAGS[n-1]}"
            SKIP_LAYERS=$n
            break
        fi
    done

    if [[ $SKIP_LAYERS -eq 0 ]]; then
        print_warning "No pre-built base image found — building all layers from scratch."
    fi
else
    print_info "Skipping remote registry check (--skip-registry-check)."
fi

# --------------- Build layers sequentially -------------------------------------------------------
PREV_IMAGE=""
if [[ $SKIP_LAYERS -gt 0 ]]; then
    PREV_IMAGE="${IMAGE_TAGS[SKIP_LAYERS-1]}"
fi

for (( i=SKIP_LAYERS; i<${#DOCKERFILES[@]}; i++ )); do
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
