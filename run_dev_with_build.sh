#!/bin/bash
# Build image layers then launch the dev container
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
export ISAAC_ROS_WS="$(pwd)/.."

./scripts/run_dev.sh
