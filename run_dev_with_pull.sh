#!/bin/bash
# Pull a pre-built image from registry, then launch the Zephyr dev container (skip local build)
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
export ZEPHYR_WS="$(pwd)/.."

ROBOT_ENV_FILE="/etc/zephyr/robot.env"
if [[ ! -f "$ROBOT_ENV_FILE" ]]; then
  echo "ERROR: Required robot environment file is missing: $ROBOT_ENV_FILE" >&2
  echo "Create it with the deployment credentials before starting the container." >&2
  exit 1
fi

if [[ ! -r "$ROBOT_ENV_FILE" ]]; then
  echo "ERROR: Robot environment file is not readable: $ROBOT_ENV_FILE" >&2
  exit 1
fi

# Login to the Docker registry
REGISTRY="registry.jihulab.com"
REGISTRY_USER="${REGISTRY_USER:-gitlab+deploy-token-14567}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-gldt-2MGMFUpyCsmerext2sK6}"

source "./scripts/ensure_docker.sh"

ZEPHYR_DATA_AGENT_DEPLOY_DIR="${ZEPHYR_DATA_AGENT_DEPLOY_DIR:-${HOME}/zephyr-data-platform-agent-dev/deploy}"
ZEPHYR_DATA_AGENT_REQUIRED="${ZEPHYR_DATA_AGENT_REQUIRED:-0}"

start_zephyr_data_agent() {
  local compose_file="${ZEPHYR_DATA_AGENT_DEPLOY_DIR}/docker-compose.yml"
  local env_file="${ZEPHYR_DATA_AGENT_DEPLOY_DIR}/.env"
  local -a compose_cmd=(
    docker compose
    --project-directory "$ZEPHYR_DATA_AGENT_DEPLOY_DIR"
    --env-file "$env_file"
    -f "$compose_file"
  )

  if [[ "$ZEPHYR_DATA_AGENT_REQUIRED" != "0" && "$ZEPHYR_DATA_AGENT_REQUIRED" != "1" ]]; then
    echo "ERROR: ZEPHYR_DATA_AGENT_REQUIRED must be 0 or 1." >&2
    return 1
  fi

  if [[ ! -f "$compose_file" || ! -f "$env_file" ]]; then
    echo "WARNING: Zephyr Data Agent deployment is incomplete: $ZEPHYR_DATA_AGENT_DEPLOY_DIR" >&2
    if [[ "$ZEPHYR_DATA_AGENT_REQUIRED" == "1" ]]; then
      return 1
    fi
    return 0
  fi

  if ! "${compose_cmd[@]}" config --quiet; then
    echo "WARNING: Zephyr Data Agent Compose configuration is invalid." >&2
    if [[ "$ZEPHYR_DATA_AGENT_REQUIRED" == "1" ]]; then
      return 1
    fi
    return 0
  fi

  echo "➡️ Ensuring Zephyr Data Agent is running"
  if ! "${compose_cmd[@]}" up -d --no-build; then
    echo "WARNING: Zephyr Data Agent failed to start; continuing with the robot container." >&2
    if [[ "$ZEPHYR_DATA_AGENT_REQUIRED" == "1" ]]; then
      return 1
    fi
    return 0
  fi

  "${compose_cmd[@]}" ps zephyr-data-agent || true
  return 0
}

start_zephyr_data_agent

printf '%s\n' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" --username "$REGISTRY_USER" --password-stdin

# Pull image from registry
PLATFORM="$(uname -m)"
REGISTRY_PROJECT="${REGISTRY_PROJECT:-robot_group/zephyr_ws}"
IMAGE_REMOTE="${IMAGE_REMOTE:-$REGISTRY/$REGISTRY_PROJECT/zephyr_dev_24.04-$PLATFORM:latest}"
IMAGE_LOCAL="zephyr_dev_24.04-$PLATFORM:latest"

# Pull image with retry logic
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_DELAY="${RETRY_DELAY:-30}"

echo "🔄 Pulling image: $IMAGE_REMOTE"
for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
  if docker pull "$IMAGE_REMOTE"; then
    echo "✅ Successfully pulled: $IMAGE_REMOTE"
    break
  fi

  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    echo "❌ Failed to pull the image after $MAX_RETRIES attempts. Please check network or image name."
    exit 1
  fi

  echo "⚠️  Pull failed (attempt $attempt/$MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done

docker tag "$IMAGE_REMOTE" "$IMAGE_LOCAL"
echo "➡️ Tagged locally as: $IMAGE_LOCAL"

# Run container — skip build since we already pulled the image
./scripts/run_dev.sh -b
