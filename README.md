# Setup develop enviroment

## Init repo
```
./setup_ws.sh
```

## Run develop docker with pull exit image
```
./run_dev_with_pull.sh
```

This also ensures the standalone Zephyr Data Agent is running from
`~/zephyr-data-platform-agent-dev/deploy`. Set
`ZEPHYR_DATA_AGENT_DEPLOY_DIR` to use another deployment directory. Agent
startup failures are warnings by default so data collection cannot block the
robot container; set `ZEPHYR_DATA_AGENT_REQUIRED=1` to make them fatal.

Codex IDE/CLI history is persisted on the host in `.codex-container` next to
this workspace. Set `CODEX_STATE_DIR` before launching to use another host
directory.

## (Optional) Run develop docker with build image from Dockerfile

```
./run_dev_with_build.sh
```

## Robot identity and credentials

The host's `/etc/zephyr/robot.env` is the single configuration used by both
container launch paths. Docker reads it as `KEY=value`; do not add `export` or
shell quoting. After enrollment, install the generated private credential file:

```bash
sudo python3 scripts/install_robot_credentials.py \
  --credentials "$HOME/.config/zephyr/robot.env" --reader-gid "$(id -g)"
```

The installer replaces only `ROBOT_ID`, `ROBOT_API_KEY` and `ROBOT_BACKEND_URL`,
preserves other device settings, and atomically installs a root-owned file with
mode `640` and the operator's group. Keep the enrollment output out of git.

Use `./scripts/run_dev.sh -b` to enter the container. New containers and terminals
opened through this script automatically receive the host configuration; no
manual credential `source` is needed. Existing terminals and running ROS nodes
retain their previous environment. Restart those nodes from the new terminal
after credential changes. Direct `docker exec` calls into an old container need
`--env-file /etc/zephyr/robot.env` until the container is recreated.

## J401 GMSL camera in the Zephyr container

For four cameras, use this single launch inside the existing development container:

```bash
ros2 launch zephyr_gmsl_camera gmsl_surround.launch.py use_intra_process_comms:=true
```

Ports 0/1/2/3 are confirmed as front_right/front_left/back_left/back_right.
Topics use `/cameras/<direction>/image_raw`; the mapping is stored in
the package's `config/surround_cameras.yaml`.
See the [four-camera validation and change record](docs/gmsl/four-camera-2026-10-19.md)
for snapshots, measured transport rates and calibration prerequisites.
The single-camera entry point below remains available; do not run both against the same device.

See the [camera package README](src/zephyr_common/zephyr_gmsl_camera/README.md) and
[one-time deployment instructions](docs/gmsl/README.md). Once the package is built and
the workspace environment is sourced, daily startup inside the development container is:

```bash
ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py
```

The camera package is maintained in `src/zephyr_common/zephyr_gmsl_camera`.
The C++ component `zephyr_gmsl_camera::GmslCameraNode` configures and captures the camera,
then publishes image_raw, camera_info and JPEG topics under `/camera/gmsl`.
The launch creates a component container by default; set `target_container:=/robot_container`
to load into an existing one. No additional camera startup script is required.

## Front fisheye panorama (2026-10-28)

The C++ composable package [zephyr_surround_vision](src/zephyr_perception/zephyr_surround_vision/README.md)
starts the front pair, panorama and preview with one command inside the existing Docker:

```bash
ros2 launch zephyr_surround_vision panorama.launch.py
```

Stop any launch owning the same cameras first. Default output is 1024×512, 180°×90°,
target 20 Hz at `/surround/front/image_raw`; JPEG uses `/surround/front/image_raw/compressed`.
Preview is off by default; pass `preview_port:=8892` for standalone inspection. Calibration saving stays off.
See the [implementation and measured limitations](docs/gmsl/panorama-package-2026-10-28.md).
