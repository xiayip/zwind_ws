#!/usr/bin/env bash
# Join the robot to the Tailnet during host boot.  This deliberately runs on
# the host: the ROS container uses host networking and inherits this connection.
set -euo pipefail

ROBOT_ENV_FILE="${ROBOT_ENV_FILE:-/etc/zephyr/robot.env}"

log() {
  printf '[tailscale] %s\n' "$*"
}

if ! command -v tailscale >/dev/null 2>&1; then
  log "tailscale CLI is not installed; skipping Tailnet registration."
  exit 0
fi

if ! systemctl is-active --quiet tailscaled; then
  log "tailscaled is not active; attempting to start it."
  systemctl start tailscaled
fi

if tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
  log "Already connected to the Tailnet."
  exit 0
fi

if [[ ! -r "$ROBOT_ENV_FILE" ]]; then
  log "Missing $ROBOT_ENV_FILE; cannot perform first-time Tailnet registration."
  exit 0
fi

if [[ $(stat -c '%a' "$ROBOT_ENV_FILE") -gt 600 ]]; then
  log "$ROBOT_ENV_FILE permissions are too broad; expected owner-only access (0600)."
  exit 0
fi

# robot.env uses KEY=VALUE lines. Source it only in this root-owned service and
# never print the values, especially TAILSCALE_AUTH_KEY.
# shellcheck disable=SC1090
source "$ROBOT_ENV_FILE"

if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
  log "TAILSCALE_AUTH_KEY is not configured; skipping first-time Tailnet registration."
  exit 0
fi

hostname="${TAILSCALE_HOSTNAME:-$(hostname -s)}"
up_args=(
  --auth-key="$TAILSCALE_AUTH_KEY"
  --hostname="$hostname"
)

if [[ -n "${TAILSCALE_ADVERTISE_TAGS:-}" ]]; then
  up_args+=(--advertise-tags="$TAILSCALE_ADVERTISE_TAGS")
fi

if [[ -n "${TAILSCALE_ACCEPT_DNS:-}" ]]; then
  up_args+=(--accept-dns="$TAILSCALE_ACCEPT_DNS")
fi

log "Registering host as '$hostname' (the auth key is not logged)."
tailscale up "${up_args[@]}"

if tailscale ip >/dev/null 2>&1; then
  log "Tailnet registration complete."
else
  log "tailscale up returned successfully, but no Tailnet IP is available yet."
  exit 1
fi
