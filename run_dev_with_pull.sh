#!/bin/bash
# Login to the Docker registry
docker login registry.jihulab.com -u gitlab+deploy-token-14567 -p gldt-2MGMFUpyCsmerext2sK6
# Pull image from registry
PLATFORM="$(uname -m)"
IMAGE_NAME="registry.jihulab.com/robot_group/zwind_ws/isaac_ros_dev-$PLATFORM"
docker pull $IMAGE_NAME
if [ $? -ne 0 ]; then
    echo "Failed to pull the image $IMAGE_NAME. Please check your network connection or the image name."
    exit 1
fi
echo "Successfully pulled the image $IMAGE_NAME."
# Run the container with the pulled image
./src/zwind_common/isaac_ros_common/scripts/run_dev.sh -b

