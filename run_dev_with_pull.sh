#!/bin/bash

# Login to the Docker registry
docker login registry.jihulab.com -u gitlab+deploy-token-14567 -p gldt-2MGMFUpyCsmerext2sK6

# Pull image from registry
PLATFORM="$(uname -m)"
IMAGE_REMOTE="registry.jihulab.com/robot_group/zwind_ws/isaac_ros_dev-$PLATFORM:latest"
IMAGE_LOCAL="isaac_ros_dev-$PLATFORM:latest"

docker pull "$IMAGE_REMOTE"
if [ $? -ne 0 ]; then
  echo "❌ Failed to pull the image $IMAGE_REMOTE. Please check network or image name."
  exit 1
fi
echo "✅ Successfully pulled: $IMAGE_REMOTE"

docker tag "$IMAGE_REMOTE" "$IMAGE_LOCAL"
echo "➡️ Tagged locally as: $IMAGE_LOCAL"

./src/zwind_common/isaac_ros_common/scripts/run_dev.sh -b
