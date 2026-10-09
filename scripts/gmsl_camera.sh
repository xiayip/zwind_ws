#!/usr/bin/env bash
# Manage only this workspace's GMSL ROS launch, inside the existing dev container.
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_FILE="$WS_DIR/src/zephyr_common/zephyr_gmsl_camera/launch/gmsl_camera.launch.py"
RUN_DIR="$WS_DIR/log/gmsl_camera"
PID_FILE="$RUN_DIR/launch.pid"
LOG_FILE="$RUN_DIR/camera.log"
action=${1:-run}
(( $# == 0 )) || shift

running() {
  [[ -r "$PID_FILE" ]] || return 1
  read -r camera_pid < "$PID_FILE"
  [[ "$camera_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -r /proc/$camera_pid/cmdline ]] || return 1
  tr '\0' '\n' < "/proc/$camera_pid/cmdline" | grep -Fxq "$LAUNCH_FILE"
}

case "$action" in
  status)
    if running; then echo "GMSL launch running: PID $camera_pid; log: $LOG_FILE";
    else echo 'GMSL launch is stopped'; exit 1; fi
    ;;
  stop)
    if running; then
      # ROS launch uses SIGINT for orderly child shutdown; SIGTERM can orphan nodes.
      kill -INT "$camera_pid"
      for ((i=0; i<50; i++)); do
        if ! running; then echo 'GMSL launch stopped'; exit 0; fi
        sleep 0.2
      done
      echo "GMSL launch did not stop; inspect $LOG_FILE" >&2
      exit 1
    fi
    echo 'GMSL launch is already stopped'
    ;;
  start)
    [[ -f /.dockerenv ]] || { echo 'Run inside the Zephyr development container.' >&2; exit 1; }
    if running; then echo "GMSL already running: PID $camera_pid"; exit 0; fi
    mkdir -p "$RUN_DIR"
    # Bash background jobs inherit ignored INT/QUIT; reset them before ROS launch.
    nohup env --default-signal=INT,QUIT bash "$SCRIPT_DIR/gmsl_camera.sh" run "$@" >> "$LOG_FILE" 2>&1 </dev/null &
    for ((i=0; i<50; i++)); do
      if running; then echo "GMSL launch started: PID $camera_pid; log: $LOG_FILE"; exit 0; fi
      sleep 0.2
    done
    echo "GMSL launch failed to start; inspect $LOG_FILE" >&2
    exit 1
    ;;
  run)
    [[ -f /.dockerenv ]] || { echo 'Run inside the Zephyr development container.' >&2; exit 1; }
    mkdir -p "$RUN_DIR"
    exec 9>"$RUN_DIR/launch.lock"
    flock -n 9 || { echo 'Another workspace GMSL launch holds the lock' >&2; exit 1; }
    source "$WS_DIR/install/setup.bash"
    printf '%s\n' "$$" > "$PID_FILE"
    # Legacy entry point. The C++ component must already be built in this workspace.
    exec ros2 launch --noninteractive "$LAUNCH_FILE" "$@"
    ;;
  *) echo "Usage: $0 {run|start|stop|status} [ROS launch arguments]" >&2; exit 2 ;;
esac
