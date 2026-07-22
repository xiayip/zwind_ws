#!/bin/bash

# This file is sourced by workspace-entrypoint.sh as root. The Agent itself is
# run as the dynamically-created container user so that it can write to the
# host-owned bind mounts used for recordings and persistent state.

if [[ -z "${FOXGLOVE_DEVICE_TOKEN:-}" ]]; then
    echo "Foxglove Agent disabled: FOXGLOVE_DEVICE_TOKEN is not set"
    return 0
fi

FOXGLOVE_AGENT_BIN="$(command -v foxglove-agent || true)"
if [[ -z "${FOXGLOVE_AGENT_BIN}" ]]; then
    echo "Foxglove Agent cannot start: foxglove-agent executable was not found" >&2
    return 1
fi

if [[ -z "${STORAGE_ROOT:-}" || -z "${VARDIR:-}" ]]; then
    echo "Foxglove Agent cannot start: STORAGE_ROOT and VARDIR must be set" >&2
    return 1
fi

mkdir -p "${STORAGE_ROOT}" "${VARDIR}"
if ! chown "${USERNAME}:${USERNAME}" "${STORAGE_ROOT}" "${VARDIR}"; then
    echo "Foxglove Agent cannot start: failed to prepare storage permissions" >&2
    return 1
fi

echo "Starting Foxglove Agent for device '${DEVICE_NAME:-token-linked-device}'"
gosu "${USERNAME}" "${FOXGLOVE_AGENT_BIN}" &
FOXGLOVE_AGENT_PID=$!

# Catch immediate configuration or authentication-independent startup errors.
sleep 1
if ! kill -0 "${FOXGLOVE_AGENT_PID}" 2>/dev/null; then
    wait "${FOXGLOVE_AGENT_PID}"
    FOXGLOVE_AGENT_STATUS=$?
    echo "Foxglove Agent exited during startup (status=${FOXGLOVE_AGENT_STATUS})" >&2
    return "${FOXGLOVE_AGENT_STATUS}"
fi

echo "Foxglove Agent started (pid=${FOXGLOVE_AGENT_PID})"
