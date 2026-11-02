# zephyr_surround_vision

前方双鱼眼拼接首版：原 Zephyr Docker 内运行的 C++ ROS2 组件，默认输出
1024×512、180°×90°，目标20 Hz。一个 launch 启动相机和拼接；网页预览默认关闭，需显式开启；
不启动标定保存。后视可切换 `view:=back`，完整360°和俯视BEV尚未实现。
本版为几何投影＋内容自适应接缝，不含学习模型，近处物体仍可能有视差。

C++ ROS 2 composable panorama renderer for the Zephyr J401 four-fisheye rig.
First release: front (or back) two-camera equirectangular panorama. The runtime
subscribes to ROS images; it never opens camera devices. All processing remains
in the existing Zephyr development Docker. No learned model is used in v0.1.

## Start with one launch

Stop the existing calibration/camera launch first so it releases the same cameras.
Inside the existing Docker:

```bash
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
source install/setup.bash
ros2 launch zephyr_surround_vision panorama.launch.py
```

This starts only front_left + front_right and the panorama component in
`/surround_front_container`, with intra-process communication. Device paths are
resolved from calibrated sysfs sensor names, including when an Orbbec changes
`/dev/videoN` enumeration. Calibration saving is not started.

LAN preview is **off by default** (`preview_port:=0`), with no HTTP server or
preview JPEG disk writes. To enable it, pass `preview_port:=8892`; then open
`http://192.168.88.121:8892/` (about 1 fps, independent of ROS rate).
No additional script is needed. This flag does not disable ROS compressed images
or LiveKit encoding.
Only the dedicated preview directory is served. Ctrl+C closes launch-owned cameras,
renderer and preview server. On input loss, ROS output stops and the page marks
its last image stale rather than presenting it as current.

## Topics

| Topic | Content |
|---|---|
| `/surround/front/image_raw` | RGB8 1024×512, 180°×90° equirectangular view, default target 20 Hz |
| `/surround/front/image_raw/compressed` | Standard image_transport JPEG, encoded when subscribed |
| `/surround/front/valid_mask` | mono8 at 2 Hz: 255 where at least one source supports the projection |
| `/surround/front/camera_mask` | mono8 at 2 Hz: 0 unknown, 1 from_camera, 2 to_camera; dominant source in feather band |
| `/surround/front/debug/image_raw` | Image with yellow seam overlay |
| `/surround/front/status` | JSON: state, fps, processing time, pair delta, input age, source stamps, errors, model limits |

Images/masks use best-effort sensor QoS. Masks/debug are generated/published for
subscribers. Diagnostic masks are throttled separately from video; use their own
headers, not a one-mask-per-video-frame assumption. Set component `mask_rate_hz`
equal to `rate_hz` when per-frame masks are required, accepting the extra bandwidth.
Output stamp is the later of the two source stamps. Camera matching
uses source timestamps (default <=25 ms); stale inputs expire using steady-clock
receipt age (250 ms). Frames are never reused for successive output pairs.
This is software pairing, not verified hardware exposure synchronization.

The panorama is not pinhole: no fabricated CameraInfo is published. For a pixel
center (u,v), longitude = ((u+0.5)/width−0.5)×horizontal_fov, downward latitude =
((v+0.5)/height−0.5)×vertical_fov. Its frame is `front_panorama_optical_frame`;
the forward axis bisects the two optical axes, and up/down is derived from their
axes. It has no calibrated base_link/gravity transform and is not metric BEV.

## Options

```bash
# Rear pair, same renderer; image left/right is the view looking backwards.
ros2 launch zephyr_surround_vision panorama.launch.py view:=back

# Existing camera streams, without opening devices again.
ros2 launch zephyr_surround_vision panorama.launch.py start_cameras:=false

# Load into an existing shared container for intra-process delivery.
ros2 launch zephyr_surround_vision panorama.launch.py \
  start_cameras:=false target_container:=/gmsl_calibration_container

# Geometry baseline for comparisons; 0 means infinity/rotation-only projection.
ros2 launch zephyr_surround_vision panorama.launch.py \
  seam_mode:=fixed reference_depth_m:=0 preview_port:=0
```

Other launch arguments: `output_width`, `output_height`, `rate_hz`,
`horizontal_fov_deg`, `vertical_fov_deg`, `max_pair_delta_ms`, `calibration_file`,
`preview_port`, `preview_bind`, `preview_directory`, `opencv_threads`. Defaults are in the launch.
Two simultaneous front/back launches need different preview ports (e.g. 8892/8893).
Higher-resolution output is optional: `output_width:=1280 output_height:=640`.
When loading into an existing container, its lifecycle owns the components;
stopping this launch does not unload them. Use `ros2 component unload` or stop
that container before repeating the load.
The existing container must have been started with this package's install prefix
in its environment. A container started before the package was first built must
be restarted after sourcing the updated workspace.

Direct component plugin: `zephyr_surround_vision::PanoramaNode`. Additional startup
parameters: `input_a`, `input_b`, `max_input_age_ms`, `seam_update_hz`,
`seam_search_deg`, `feather_px`, `exposure_compensation`, `mask_rate_hz`. Parameters are read-only
after startup; restart/reload to change geometry or thresholds. Exact input
dimensions and optical frame IDs are checked against the rig file.

## Projection and limitations

- Full-angle KB4 (`atan2`): supports observed fisheye rays beyond 90°; monotonicity
  and proper relative rotation are checked. Source maps are precomputed once.
- Default assumed 3 m sphere includes both camera centers and relative translation.
  It is not estimated scene depth. `reference_depth_m:=0` uses directions at infinity.
- Adaptive seam: low-resolution image/color/edge disagreement costs, vertical
  dynamic-programming path, temporal penalty, and limited seam motion at 2 Hz.
  A narrow blend avoids broad ghosting. A fixed-seam baseline remains available.
- Exposure: robust overlap median ratio, bounded gain and temporal smoothing.
- CPU OpenCV renderer uses existing distro dependencies. It is not a zero-copy
  GPU or TensorRT implementation; capture can use intra-process shared messages,
  while rendering/output still allocate/copy pixels.
- The bundled `surround_container` is a standard ROS ComponentManager with four
  executor threads. It sets OpenCV/TBB to four workers before loading components,
  avoiding concurrent changes to process-wide OpenCV settings. `opencv_threads`
  changes this launch-owned process only; loading into an existing container
  inherits that process's OpenCV configuration and does not change it.
- Adaptive seams can reduce cuts but cannot guarantee complete objects under
  large parallax, occlusion, textureless scenes or motion. v0.1 performs no dense
  local alignment, depth prediction, semantic preservation or generative filling.
  Unknown areas stay black; valid masks describe projection support, not obstacle
  absence or guarantees that every object survives compositing.

`config/rig_20261028.yaml` is the development calibration snapshot for this physical
rig, exported from the AprilGrid review (source hashes included). Parameters are
now consumed only by this panorama renderer; driver CameraInfo/TF are unchanged.
Recalibrate after remounting. Do not deploy these rig-specific poses to another board.

## Build, validate, and reproduce

```bash
colcon build --packages-select zephyr_surround_vision --symlink-install \
  --cmake-args -DCMAKE_BUILD_TYPE=Release
colcon test --packages-select zephyr_surround_vision
colcon test-result --test-result-base build/zephyr_surround_vision --verbose
```

No new system/Docker dependencies were required on the current board. Required
libraries are OpenCV core/imgproc/imgcodecs/features2d, yaml-cpp, and the ROS dependencies in
package.xml. See workspace `docs/gmsl/panorama-package-2026-10-28.md` for measured
results and changes. No scripts are required for daily startup beyond the launch.

On this board, the 1024×512 profile measured about 19.7 fps with an intra-process
C++ subscriber and 19.5 fps with a separate JPEG subscriber. These are short tests,
not end-to-end Quest latency or long-duration guarantees. Simultaneous raw, JPEG
and mask subscriptions across processes dropped frames (about 16 fps raw in a
20-second C++ test). Prefer intra-process raw for C++ consumers and compressed
transport for remote viewing. The default 2 Hz masks avoid sending two additional
full-size diagnostic images at video rate. All earlier benchmark results are kept.

The optional offline C++ tool uses the identical renderer:

```bash
ros2 run zephyr_surround_vision render_pair RIG.yaml front A.png B.png OUTPUT_DIR adaptive 3
```

## Extension points

`PairRenderer` is independent of ROS; `PairBuffer` owns bounded timing rules;
`PanoramaNode` handles transport, diagnostics and optional preview. Full 360 needs
the missing side-pair extrinsics and loop validation; BEV needs a ground/base
transform. Add separate projection/rendering strategies and output namespaces
when those exist. A future learned alignment backend belongs between projection
and composition, while keeping the input synchronization and diagnostics.

## Parallax investigation and candidate seam mode (2026-10-28)

The ~0.454 m front baseline and the fixed 3 m reference sphere cause depth-dependent
misregistration. A near feature can be omitted and a far feature duplicated by the
same cut. Changing `reference_depth_m` moves the well-aligned depth; it does not
align all scene depths. This is independent of the missing base/ground transform.

An opt-in C++ `seam_mode:=parallax` candidate adds feature ownership protection to
adaptive seam selection. Mutual ratio-filtered ORB matches are checked against
calibrated epipolar geometry. The interval between each pair of projections is
penalized: cutting there would select the feature twice or not at all. Ordinary
seam motion remains limited; the limit may be bypassed to leave a newly protected
interval. Fewer than six accepted matches falls back to the existing adaptive
cost. A scene with no feasible safe cut still has residual errors; this is not a
complete foreground/background registration algorithm or a depth estimator.

No local deformation or invented texture is applied. The existing ERP ray model,
reference sphere, output size and timestamps are unchanged. The candidate remains
opt-in: the production default is still `adaptive`, and preview remains off.

New status fields in the candidate build:

- `seam_mode`: selected mode.
- `correspondence_count`: accepted feature pairs at the latest seam update.
- `parallax_guard`: whether enough pairs enabled the guard.
- `seam_conflict_fraction`: fraction of output rows where the actual seam still
  crosses a protected interval. Zero is not a guarantee of complete objects:
  textureless regions, occlusions and missed matches are not represented.

For an isolated evaluation while the normal camera drivers are running, source
an independently built candidate overlay, then use:

```bash
ros2 launch zephyr_surround_vision panorama.launch.py \
  start_cameras:=false output_namespace:=/surround_candidate \
  container_name:=surround_front_candidate_container \
  seam_mode:=parallax preview_port:=0
```

This subscribes to the existing cameras and publishes
`/surround_candidate/front/image_raw`; it does not replace the LiveKit input. Stop
it after evaluation to release its extra CPU load. Do not run a second set of
camera drivers. For normal deployment, rebuild the package while its libraries
are not mapped by running containers; never overwrite an in-use shared library.

The offline `render_pair` utility accepts `fixed|adaptive|parallax|primary_a`, reports the
seam diagnostics and render time, and also writes `projected_a.jpg` and
`projected_b.jpg`. These are the individual calibrated projections before seam
selection, useful for distinguishing optical blind spots from deleted content.

A second opt-in mode, `seam_mode:=primary_a`, prioritizes camera A (front_left for
front, back_left for back) across the central view. It moves the transition toward
the other camera's side, bounded by valid coverage and half `seam_search_deg`
(default 35 degrees). It uses a precomputed mask and feathering, without feature
matching. This preserves continuous central-view content from one source but
moves residual parallax to the periphery; it is not all-depth seamless stitching.
Actual coverage limits can bring the transition inward, especially near the floor.

The all-in-one entrypoint now forwards `surround_seam_mode` for front and
`surround_back_seam_mode` for rear (both still default to `adaptive`). After the
candidate package is deliberately deployed/rebuilt, selecting a mode still needs
only one normal launch, for example:

```bash
ros2 launch z2_bringup z2_launch_all.launch.py surround_seam_mode:=primary_a
```

During this investigation the new binaries are installed only in the isolated
`log/surround_vision/parallax-20261028/install` overlay. The original live library
has not been overwritten and the running Quest feed still uses the old adaptive
mode. Do not expect the new modes in an unsourced old install.

Nine C++ tests cover projection, pairing, legacy seam behavior, featureless
fallback, protected-seam source preservation and primary-source ownership in
both front/rear orientations. Saved-frame evaluation does not establish moving
obstacle preservation or real-time acceptance. The separate-process camera
subscription trial was functional but too slow for deployment; retain the
existing intra-process driver/render architecture when evaluating performance.

An offline evaluation of the released StabStitch++ spatial model on these camera
pairs did not pass visual acceptance: board and background displacement remained
in ERP, rectified and raw-fisheye variants. This was spatial-only inference, not
the complete temporal model. No learned model is included in this ROS package.
Its mesh output also does not retain calibrated ERP rays. See the integration
log for exact model provenance, environment, performance scope and limitations.
