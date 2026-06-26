#!/bin/bash
# Build image layers then launch the Zephyr dev container
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
export ZEPHYR_WS="$(pwd)/.."

./scripts/run_dev.sh
