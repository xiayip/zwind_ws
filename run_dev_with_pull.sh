#!/bin/bash

docker login registry.jihulab.com -u gitlab+deploy-token-14567 -p gldt-2MGMFUpyCsmerext2sK6

docker pull registry.jihulab.com/robot_group/zwind_ws/isaac_ros_dev-x86_64

./src/zwind_common/isaac_ros_common/scripts/run_dev.sh -b

