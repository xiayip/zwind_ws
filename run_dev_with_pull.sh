#!/bin/bash
# Pull a pre-built image from registry, then launch the Zephyr dev container (skip local build)
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
export ZEPHYR_WS="$(pwd)/.."

ROBOT_ENV_FILE="/etc/zephyr/robot.env"
if [[ ! -f "$ROBOT_ENV_FILE" ]]; then
  echo "ERROR: Required robot environment file is missing: $ROBOT_ENV_FILE" >&2
  echo "Create it with the deployment credentials before starting the container." >&2
  exit 1
fi

if [[ ! -r "$ROBOT_ENV_FILE" ]]; then
  echo "ERROR: Robot environment file is not readable: $ROBOT_ENV_FILE" >&2
  exit 1
fi

if [[ $(stat -c '%a' "$ROBOT_ENV_FILE") -gt 600 ]]; then
  echo "ERROR: Robot environment file permissions are too broad: $ROBOT_ENV_FILE" >&2
  echo "Expected owner-only access (for example: sudo chmod 600 $ROBOT_ENV_FILE)." >&2
  exit 1
fi

# Login to the Docker registry
REGISTRY="registry.jihulab.com"
REGISTRY_USER="${REGISTRY_USER:-gitlab+deploy-token-14567}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-gldt-2MGMFUpyCsmerext2sK6}"

source "./scripts/ensure_docker.sh"

printf '%s\n' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" --username "$REGISTRY_USER" --password-stdin

# Pull image from registry
PLATFORM="$(uname -m)"
REGISTRY_PROJECT="${REGISTRY_PROJECT:-robot_group/zephyr_ws}"
IMAGE_REMOTE="${IMAGE_REMOTE:-$REGISTRY/$REGISTRY_PROJECT/zephyr_dev_24.04-$PLATFORM:latest}"
IMAGE_LOCAL="zephyr_dev_24.04-$PLATFORM:latest"

# Pull image with retry logic
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_DELAY="${RETRY_DELAY:-30}"

echo "🔄 Pulling image: $IMAGE_REMOTE"
for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
  if docker pull "$IMAGE_REMOTE"; then
    echo "✅ Successfully pulled: $IMAGE_REMOTE"
    break
  fi

  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    echo "❌ Failed to pull the image after $MAX_RETRIES attempts. Please check network or image name."
    exit 1
  fi

  echo "⚠️  Pull failed (attempt $attempt/$MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done

docker tag "$IMAGE_REMOTE" "$IMAGE_LOCAL"
echo "➡️ Tagged locally as: $IMAGE_LOCAL"

# Run container — skip build since we already pulled the image
./scripts/run_dev.sh -b
