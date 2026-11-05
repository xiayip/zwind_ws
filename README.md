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

## MPC / OCS2 development dependencies

This workspace uses [ocs2_ros2 v1.4.0](https://github.com/legubiao/ocs2_ros2/tree/v1.4.0)
from source. `dev.repos` pins its commit. The ROS 2 repository contains both the
OCS2 algorithms and ROS interfaces;
do not also import the ROS 1 `leggedrobotics/ocs2` repository or `arms_ros2_control`.

- **Image:** Ubuntu Boost, Eigen, OpenMP, URDF development headers, ROS Pinocchio,
  ROS control/message/TF dependencies, and Qt/RViz development dependencies.
  The existing ROS layer already installs `moveit_msgs`, `interactive_markers`,
  `ros2_control` and RViz. Do not mix system Boost with a source installation in `/usr`.
- **Source:** `ocs2_ros2` under `src/zephyr_manipulation`. The Zephyr controller
  uses our own robot model; `ocs2_robotic_assets` is not imported by default.
  Do not recursively initialize unrelated upstream example submodules.
- **Managed by OCS2:** CppAD/CppADCodeGen headers are bundled. BLASFEO and HPIPM
  are fetched at upstream-pinned commits during the first build, which requires
  GitHub access. They are needed through `ocs2_sqp`, even when our controller uses DDP.
  No additional ROS repository or system OCS2 binary is required.

After updating this repository, import the new sources from the workspace root:

```bash
vcs import --skip-existing < dev.repos
```

`--skip-existing` does not update existing checkouts: if OCS2 is already present,
check its revision against `dev.repos` before building; preserve any local changes.
Rebuild the development image with `./scripts/build_image.sh` and recreate the
container when ready. Editing a Dockerfile does not update an already-running
container; pulling an older published image does not include these dependencies.

In the **new container**, as `admin`, use a fresh terminal with no experimental
underlays sourced. Build the required OCS2 subset into the normal workspace install:

```bash
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
CMAKE_BUILD_PARALLEL_LEVEL=2 colcon build --symlink-install --executor sequential \
  --packages-up-to ocs2_mobile_manipulator ocs2_ros_interfaces ocs2_self_collision_visualization \
  --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
source install/setup.bash
ros2 pkg prefix ocs2_mobile_manipulator
```

The reported prefix should be this workspace's `install/ocs2_mobile_manipulator`,
not a directory under `log/`. The targeted build excludes unrelated upstream
advanced examples (RaiSim, MPC-Net and perceptive locomotion); this dependency set
is not intended to build every OCS2 example with an unfiltered `colcon build`.
`BUILD_TESTING=OFF` applies to this third-party library build: the upstream
`ocs2_mobile_manipulator` tests require the omitted `ocs2_robotic_assets` package.
Keep our own `mpc_controller` tests enabled by explicitly using
`-DBUILD_TESTING=ON` when building that package separately, after its dependencies
are installed. Do not set `BUILD_TESTING=OFF` as a workspace-wide default.
To run upstream robot-example tests later, import the assets revision specified
by the pinned OCS2 checkout's `.gitmodules` and gitlink before enabling those tests.
Do not load the old `log/mpc_*/environment.bash` scripts or copy their binaries
into `install/`. Reconfigure/rebuild affected packages against the new source build.

This change only prepares third-party dependencies. `zephyr_controllers` remains
on `main` in `dev.repos`, as do the other Zephyr repositories. The latest MPC
decoupling changes, new `zephyr_msgs` services and arm mock launch must be published
in their respective repositories before a fresh checkout can build/run that MPC
version. Once those changes are available, build them in the same workspace and
continue to use `source install/setup.bash`; no special runtime source script is needed.

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
