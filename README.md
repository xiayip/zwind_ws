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

## J401 GMSL camera in the Zephyr container

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
