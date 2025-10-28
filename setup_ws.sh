#!/bin/bash

# check if pip is installed
if ! command -v pip &> /dev/null; then
    echo "pip3 not found, installing pip..."
    sudo apt update
    sudo apt install -y python3-pip
fi

# check if vcs tool is installed
if ! command -v vcs &> /dev/null; then
    # install vcs tool
    echo "vcs not found, installing vcs..."
    sudo pip install vcstool
fi

# check if git-lfs is installed
if ! command -v git-lfs &> /dev/null; then
    echo "git-lfs not found, installing git-lfs..."
    sudo apt-get update
    sudo apt-get install git-lfs
fi

vcs import < dev.repos --skip-existing

cd ./src/zwind_common/isaac_ros_common/scripts
echo -e "CONFIG_IMAGE_KEY=ros2_humble.zwind\nCONFIG_DOCKER_SEARCH_DIRS=(../../../../docker/ ../docker)" > .isaac_ros_common-config
echo -e "-v $HOME/.ssh:/home/admin/.ssh:ro\n-v /dev:/dev" > .isaac_ros_dev-dockerargs
# echo -e "-v /etc/nova/:/etc/nova/\n-v /opt/nvidia/nova/:/opt/nvidia/nova/\n-v /mnt/nova_ssd/recordings:/mnt/nova_ssd/recordings" > .isaac_ros_dev-dockerargs
