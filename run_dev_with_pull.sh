#!/bin/bash
# Pull a pre-built image from registry, then launch the dev container (skip local build)
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
export ISAAC_ROS_WS="$(pwd)/.."

# Login to the Docker registry
docker login registry.jihulab.com -u gitlab+deploy-token-14567 -p gldt-2MGMFUpyCsmerext2sK6

# Pull image from registry
PLATFORM="$(uname -m)"
IMAGE_REMOTE="registry.jihulab.com/robot_group/zwind_ws/isaac_ros_dev-$PLATFORM:latest"
IMAGE_LOCAL="isaac_ros_dev-$PLATFORM:latest"

# Pull image with retry logic
MAX_RETRIES=10
RETRY_COUNT=0
RETRY_DELAY=10

echo "🔄 Pulling image: $IMAGE_REMOTE"
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  docker pull "$IMAGE_REMOTE"
  if [ $? -eq 0 ]; then
    echo "✅ Successfully pulled: $IMAGE_REMOTE"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "⚠️  Pull failed (attempt $RETRY_COUNT/$MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    else
      echo "❌ Failed to pull the image after $MAX_RETRIES attempts. Please check network or image name."
      exit 1
    fi
  fi
done

docker tag "$IMAGE_REMOTE" "$IMAGE_LOCAL"
echo "➡️ Tagged locally as: $IMAGE_LOCAL"

# Run container — skip build since we already pulled the image
./scripts/run_dev.sh -b
