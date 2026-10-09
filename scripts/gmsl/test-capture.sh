#!/usr/bin/env bash
# Stop the ROS camera container first: both tools must not capture simultaneously.
set -euo pipefail
device=${VIDEO_DEVICE:-/dev/video0}
timeout 40 v4l2-ctl -d "$device" \
  --set-fmt-video=width=1920,height=1080,pixelformat=YUYV \
  --set-ctrl=sensor_mode=1 --stream-mmap --stream-count=900 --verbose
