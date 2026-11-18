# 2026-10-09 Zephyr 工作区整合记录

## 2026-10-28：后两路标定验证与前后拼接静态预览

保持保存暂停；后左33/后右39张原图经修正角点、去重得到31/36个姿态，留出RMS为0.516/0.347px。
后方16组共同姿态拟合相对外参，双向留出误差0.495/0.860px。没有前后相机之间的侧面共同观测，
所以完整四相机坐标系仍待补采。新增四路候选 YAML，并明确未部署到 CameraInfo/TF。
在原开发 Docker 中订阅当前四路画面，生成前、后180°静态拼接预览，证实近处视差仍需处理。
新增离线诊断脚本和记录；未修改运行时 C++、系统配置、依赖、Docker 镜像或启动参数。
详见 [四路标定审查](calibration-surround-2026-10-28.md)。

## 2026-10-28：第二轮数据审查与角点定位修复

按用户要求暂停保存。前两路各33张原图，重新提取角点并再次去重后前左24、前右27个姿态；
留出重投影RMS约0.19/0.36px。公共观测15组去重为11组，外参留出检查约0.63px，足够推进首版前方拼接。
修复C++固定3px精细定位窗口，改为随标签大小调整。原PNG和观察记录未覆盖；新预览仍为暂停。
完整角度模型离线诊断、回归测试、依赖隔离和产物位置见 [第二轮审查](calibration-round2-2026-10-28.md)。

## 2026-10-28：AprilGrid 实物核对、自动采集与内参候选工具

新增 C++ 标定采集组件、单一 launch、网页计数与提示音、5×5/80mm/24mm 参数、离线内参候选工具。
继续使用原 Zephyr Docker；没有宿主驱动、内核、设备树或镜像改动。现有依赖足够，未安装软件。
首轮数据去重后前左11、前右7、后左2、后右1个姿态，前两路公共观测5组；暂停并保留全部数据，未部署标定。
修改、备份、验证及下一轮采集说明见 [标定记录](calibration-2026-10-28.md)。

基线：zephyr_ws HEAD `a95e441e9fd198430937473f129b4a4c7387419e`，开始时 git status 干净。
开发容器已有全工作区 colcon 编译及其他任务；本次不重建、不重启该容器。

## 持久文件变更

- 新增 `src/zephyr_common/zephyr_gmsl_camera`：ament_cmake ROS 包、launch、YAML 参数。
- `.gitignore` 从忽略整个 src 改为只放行本地相机包；其他 vcs 导入仓库继续忽略。
- 新增 `scripts/gmsl_camera.sh`：run/start/stop/status；通过 flock 和经过命令行校验的 PID 避免重复启动/误停无关进程。
- 新增 `scripts/install_gmsl_dependencies.sh`：在旧拉取镜像的开发容器内只安装缺少的包。
- `docker/Dockerfile.zephyr` 加入 v4l-utils；现有 ROS 层的两个相机包不重复增加。
- 复制主机 setup/rollback 脚本到 `scripts/startup/`；不自动修改所有机器人共用的设备配置流程。
- 复制验证脚本、历史修改记录和使用文档到工作区；README 增加入口。

## 运行态变更

- 在现有开发容器内新增 `v4l-utils 1.26.1-4build3`，apt 结果为 1 newly installed / 0 upgraded / 0 removed。
- 保留现有 `ros-jazzy-v4l2-camera 0.7.1-1noble.20260614.054314` 和 `ros-jazzy-compressed-image-transport 4.0.7-1noble.20260614.053443`。
- 执行 `docker update --restart=no j401-gmsl-camera` 和 `docker stop -t 15 j401-gmsl-camera`，原独立容器及镜像保留作历史档案。
- 改由开发容器的 admin 用户运行工作区 launch，日志/PID 在工作区 `log/gmsl_camera/` 下。
- 主机 overlay 已生效，本轮无需修改内核、设备树、启动配置或重启板子。
- 修改前四个工作区文件的备份在主机 `~/j401-gmsl/backups/zephyr-integration/`。

## 验证

- 新相机包使用独立 build/install/log 子目录完成 colcon 构建；标准 `ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py --show-args` 可正常解析。没有重建全工作区。
- 在开发容器内连续订阅 20 秒：593 帧、29.65 fps、1920×1080 RGB8、图像时间戳严格递增；600 条 CameraInfo，592 条匹配已收到图像的时间戳。CameraInfo 未标定。
- JPEG 订阅 12 秒：360 帧、30.06 fps、平均 261,514 字节/帧，JPEG 起止标记有效。
- 启停测试发现并修复两个问题：ROS launch 收到 SIGTERM 会留下采集进程；Bash 后台任务会继承忽略 SIGINT 的状态。最终后台入口用 `env --default-signal=INT,QUIT` 恢复信号，launch 显式开启 `--noninteractive`，stop 使用 SIGINT。
- 最终重复 start 保持同一 PID；stop 后 launch 退出且没有可访问进程继续打开 `/dev/video0`；重复 stop 成功；再次 start 成功。
- Python/Bash/XML 语法检查、Git diff 空白检查通过。忽略 Python 缓存，新的相机源码可以被 Git 跟踪，其他导入包仍被忽略。

- 停止后重启，再用只订阅、不映射相机设备的临时容器复测：原始图像 20 秒 591 帧、29.54 fps、CameraInfo 600 条、590 条匹配；JPEG 12 秒 361 帧、30.07 fps、平均 263,939 字节/帧。临时订阅容器已自动删除，发布节点始终在 Zephyr 开发容器中。
- 以上 Python best-effort 原始图像订阅存在少量掉帧；不能据此声称端到端无丢帧。V4L2 的 900 帧无序号缺口测试属于此前主机调试结果。

原始操作/测试日志保存到工作区 `log/gmsl_camera/integration/`。实拍 RGB 帧在 `log/gmsl_camera/verified-frame.ppm`。
测试不覆盖全工作区构建、标定、冷启动或多相机。没有推送镜像或 Git 提交。

## 后续：统一为单 launch 启动

- 新增包内 `src/zephyr_common/zephyr_gmsl_camera/README.md`，通过 CMake 安装到包的 share 目录。说明单 launch 启动、Ctrl+C 停止、话题、参数、一次性部署和上层 launch 的 include 方式。
- 工作区 README 和本目录 README 的日常入口统一为 `ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py`。设备检查和 sensor_mode/格式设置原本就在 launch 内完成，不需要额外启动脚本。
- 为 launch 参数补充说明，缺少依赖时指向一次性部署文档。旧管理脚本保留作调试档案，日常不依赖它。
- 以 admin 身份运行标准 `colcon build --symlink-install --packages-select zephyr_gmsl_camera`，包已安装到工作区 `install/zephyr_gmsl_camera`，不再只存在于此前隔离验证的 install 子目录。
- 新终端仍需按 ROS 标准加载 `install/setup.bash`；没有修改用户 shell 初始化配置。
- 停止之前的脚本后台节点，在交互终端直接运行上述包 launch：20 秒收到 585 帧、29.30 fps，CameraInfo 599 条；JPEG 12 秒 360 帧、30.08 fps，验证通过。
- 实际发送 Ctrl+C 后，相机节点 clean exit，launch 正常退出。测试节点已停止，设备留给用户通过 launch 启动。
- 启动日志出现一次帧尺寸枚举 Invalid argument，随后按设定的 1080p 成功采集；未标定提示仍存在。没有在本轮替换相机驱动或 ROS 依赖版本。
- 本轮开始时 `.gitignore` 已被改回忽略整个 `src/`，本轮保留该规则。包及 README 实际存在于源码目录；后续通过 Git 分发时需将该包纳入版本管理或配置独立源码仓库。
- 修改前文件备份：`~/j401-gmsl/backups/single-launch-readme/before.tar`。原始日志：工作区 `log/gmsl_camera/single-launch/`。

## 后续：C++ 可组合节点与包级 Git 忽略规则

- 包目录已由用户初始化为独立 Git 仓库。本轮新增包级 `.gitignore`，忽略 build/install/log、Python 缓存和编译数据库；仅将先前暂存的 `launch/__pycache__/gmsl_camera.launch.cpython-312.pyc` 从索引移除，磁盘缓存及其余暂存内容保留。没有提交或推送。
- 新增 `src/gmsl_camera_node.cpp`，注册 `zephyr_gmsl_camera::GmslCameraNode`，生成 `libgmsl_camera_component.so`。版本更新为 0.2.0。
- 相机模式设置、V4L2 MMAP 采集、RGB8 转换、image_transport/CameraInfo 发布以及释放设备全部由 C++ 完成，运行时不调用脚本或 v4l2-ctl。
- 组件支持 rclcpp NodeOptions 和 intra-process；默认 launch 创建 component_container_mt，`target_container` 可将其加载进已有容器。错误只影响该组件，不调用全局 shutdown。采集参数加载后只读。
- 初始尝试复用 v4l2_camera 0.7.1，但卸载实测发现其相机 FD 未释放；最终实现改为本包直接拥有 FD/MMAP/线程，已移除对 v4l2_camera 和 cv_bridge 的直接依赖。采用 camera_info_manager、image_transport、OpenCV 和 ROS 基础消息库。
- 所需 C++ 依赖已存在于开发容器，补齐脚本检查为无需安装。本轮没有新增 apt 包、重建/重启 Docker、修改内核或启动配置。旧 v4l2_camera 包和诊断用 v4l-utils 保留。
- 更新包内 README、工作区 README、部署说明及依赖补齐脚本。旧脚本入口改为加载工作区 install 环境以兼容已编译组件，日常仍只用 ros2 launch。
- 编译开启 C++17、Wall/Wextra/Wpedantic，最终 colcon 构建通过且无告警。ROS 环境下共享库依赖可解析，不再链接 v4l2_camera。
- 初始化验证：测试前将 sensor_mode 设为 0，组件启动后读取为 1。20 秒原始图像 592 帧、29.64 fps、1920×1080 RGB8；599 条 CameraInfo，591 条时间戳匹配；JPEG 12 秒 360 帧、30.03 fps。
- 组件测试通过：缺失设备加载被拒绝、重复采集被锁拒绝、不支持的模式修改被拒绝，原采集均继续；卸载后设备释放，容器仍存活；开启 intra-process 后收到 90 帧/3 秒，再卸载重载成功。实际原始图像 QoS 为 BEST_EFFORT。
- 已验证通过 `target_container` 加载进已有容器，加载命令退出后组件继续运行；intra-process 开启时 JPEG 360 帧/12 秒、30.00 fps。没有声称完整图像处理管线已实现零拷贝。
- 测试前备份整个包（含原 Git 索引）：`~/j401-gmsl/backups/cpp-component/`。操作、编译及失败/成功测试日志保存于工作区 `log/gmsl_camera/cpp-component/`。
- 最终卸载检查：共享容器仍运行，`/proc/<pid>/fd` 和 `maps` 均无相机 FD/MMAP 残留。另启动启用 intra-process 的采集组件实测 Ctrl+C，组件容器 clean exit，launch 返回 0。测试节点和容器已停止，设备留给用户下一次启动。

## 2026-10-19：四相机与环视话题准备

- 四路均有真实 1080p 图像，硬件同时各采 600 帧，均 30 fps。
- 新增四路 launch 与基于传感器标识的 YAML 映射，暂用 `/cameras/port0`～`port3`，等待确认实际安装方位。
- C++ 增加独立 camera_name；提供逐路标定 URL，未生成虚构内外参、TF 或 BEV。
- Docker 内四路 C++ 同进程订阅 20 秒收到 600/599/599/599 帧，均约 30 fps，CameraInfo 时间戳匹配。
- 跨进程 Python 订阅四路 raw 为 7.68～12.82 fps，JPEG 为 19.11～23.80 fps，未通过 ≥25 fps 标准；保留完整结果。
- 复用现有开发 Docker，依赖检查无需安装；没有内核、设备树、Docker 配置或镜像变更。
- 测试已结束，四路设备释放，开发容器保留运行。没有提交或推送。
- 完整变更、备份、复测方法及限制见 [四相机验证记录](four-camera-2026-10-19.md)。

## 2026-10-19：用户确认方位与硬件翻转调研

- 用户确认 0=front_right、1=front_left、2=back_left、3=back_right，已更新配置、README 和验证脚本默认名称。
- 四个方位话题、frame ID、独立标定名及 CameraInfo 匹配已实际验证；测试结束释放设备。
- VIC 离线测试验证上下翻转、左右翻转和 180°旋转；普通 admin 用户下，1080p YUYV→RGBA＋上下翻转约 1.52 ms，含 CPU 复制/同步约 3.92 ms。
- 补齐当前 Docker admin 对宿主 DRM render 节点 GID 993 的组权限，并修改 workspace-entrypoint 按实际 GID 自动设置，便于其他板子复用。
- 未将 VIC 或翻转接入生产采集代码；图像方向保持不变，没有改变内核、设备树、系统服务或持久库路径。
- 完整结果、限制、Docker 修改与备份见 [方位及 VIC 验证记录](camera-directions-and-flip-2026-10-19.md)。

## 2026-10-19：180°旋转性能对比（仅离线诊断）

- 用户确认需要旋转180°。比较 CPU RGB8 后旋转、NEON YUYV 重排后转换、融合 NEON 原型以及 VIC 路径。
- 当前配置下 NEON YUYV 重排＋RGB8 转换约 1.60 ms/帧；VIC 完整 RGB8 单线程输出约 3.81 ms，累计 CPU 时间约 2.65 ms。
- 硬件缓冲区内 VIC 转换＋旋转约 1.50 ms，未包含 CPU 输入/输出；建议后续 BEV 合并方向映射，避免独立旋转中间图。
- 真实帧和全幅随机输入的 NEON 输出与 OpenCV 参考逐字节一致。没有把诊断原型部署到采集节点，没有改动系统或 Docker 配置。
- 全部数据、适用条件与限制见 [180°旋转对比](rotation-benchmark-2026-10-19.md)。

## 2026-10-28：C++双鱼眼拼接包

- 新增 `src/zephyr_perception/zephyr_surround_vision`，C++可组合节点，单launch启动前对相机、拼接及网页。
- KB4 LUT投影、有限深度球面假设、亮度补偿、自适应接缝；默认1024×512、180°×90°、目标20 Hz。
- 实测同进程C++约19.65 fps，单独JPEG约19.46 fps；多路跨进程订阅仍掉帧，失败结果保留。
- 六个单元用例通过；真实图像/JPEG/掩码格式、时间戳、断流停止及正常关闭验证完成。
- 工作区gitignore仅放行新包；README和本次记录补齐。原驱动与标定数据保留；未修改Docker、系统依赖或驱动配置。
- 旧标定预览停止，标定保存关闭；交付时前方拼接和8892网页保持运行。
- 这是几何和自适应接缝首版，尚无学习模型、完整360°、地面BEV或Quest编码传输。
- 详见[源码、启动、性能和变更记录](panorama-package-2026-10-28.md)。

## 2026-10-28：Z2 launch-all 接入前后拼接

- z2_bringup新增surround.launch.py，launch-all默认启动四路相机、前后两个拼接组件与8892/8893预览。
- 复用panorama自带驱动加载，不重复启动四路驱动；scoped GroupAction隔离RTC同名target_container参数。
- 增加关闭全部环视、只开前视和关闭网页的参数，以及包运行依赖和README。
- 编译通过，实际环视分支前后同时出图，20秒窗口节点报告约20 Hz；无输入或渲染错误，关闭后正常释放设备。
- 整机launch未重启，原独立前视预览已恢复；下次启动launch-all前需先停止独立前视。
- 无系统/Docker修改，无Git提交。详见[接入与验证记录](z2-bringup-integration-2026-10-28.md)。

## 2026-10-28：前视全景接入 LiveKit

- teleop_rtc_cpp新增显式配置的JSON状态转发；保持robot_state的messageType/data包装，状态对象位于data.data。
- Z2 RTC配置增加front视频；保留wrist_camera，back视频暂未启用。配置前后两个status数据轨道，按对应ROS状态到达发送。
- 编译、新增隔离ROS回归测试通过；测试发现并修复重新初始化时重复状态订阅。
- 实际连接LiveKit并发布front及/surround/front/status；后端拒绝schema元数据组合，现有逻辑回退为无format metadata轨道，JSON载荷不变。
- 独立观察者token被后端固定到机器人身份，程序拒绝入房，未声称Quest接收验证完成。发送端真实状态样本和运行日志保留。
- 当前前视与RTC同组件容器运行；未启动整机控制。后续仍用launch-all，先停止调试前视会话。
- 无系统/Docker依赖变更，无Git提交。详见[RTC接入与Quest协议](rtc-panorama-2026-10-28.md)。

## 2026-10-28：用户启动日志检查与残留清理

用户18:11启动launch-all时，8892被此前调试遗留的python HTTP服务PID275668占用。
检查确认旧独立前视launch PID275563已退出，当时无surround_container进程。
核验残留进程命令确为本工作区front预览后发送SIGINT，释放8892。
未重启整机控制、未改系统/Docker配置、未清空共享内存。
日志另含Fast DDS fastrtps_port7000锁初始化错误，以及FIFO实时调度权限/200 Hz循环超时警告，
与HTTP端口冲突分别记录；不能由HTTP问题推断其原因。

## 2026-10-28：预览默认关闭与CameraInfo空URL修复

- 整机、环视和独立panorama的预览端口默认均改为0；需要时显式开启。
- 空camera_info_url明确初始化未标定CameraInfo，避免库延迟查找不存在的默认文件；显式URL仍正常加载。
- 三包编译通过；四路CameraInfo与前后真实拼接图像检查通过，没有默认标定文件报错，8892/8893未监听。
- 只运行环视分支测试，测试完成关闭，未启动整机控制；没有系统或Docker修改。
- 详见[修复与验证记录](preview-camera-info-2026-10-28.md)。

## 2026-10-28 — Front near/far parallax investigation (candidate only)

- Paused BEV work. Read-only subscriptions saved six original front pairs and five
  near-board pairs under `log/surround_vision/parallax-20261028/`. Selected timestamp
  differences: 2.627 ms for room pair 02, 4.173 ms for near-board pair 04; these
  timestamps do not prove hardware exposure synchronization.
- Reproduced omission/duplication with a fixed center seam using the same pair and
  sphere radii 1, 1.5, 2, 3, 5 m and infinity. The board is present in both original
  images. The existing adaptive seam already avoided the complete board in the
  saved static sample; do not describe a fixed-seam comparison as an improvement
  over that existing adaptive result.
- Unconstrained dense flow and coarse depth-sweep prototypes produced visible
  structural deformation/incorrect depths and were not deployed.
- Added opt-in C++ `parallax` seam mode: mutual ORB matches, calibrated epipolar
  filtering, penalties for cuts between corresponding feature projections,
  low-feature fallback, and conflict diagnostics. This guards source selection;
  it does not solve all-depth registration, occlusion, or unobserved content.
- Added opt-in `primary_a` mode: central content prefers camera A, moving the
  transition toward the side within source support and the configured seam search
  angle. Residual parallax moves to the periphery. It is not a metric view or an
  all-scene correction. Existing projection/calibration and image topics remain.
- Extended `render_pair` with pre-composite projection exports and a bounded static
  benchmark. Added isolated namespace/container launch arguments and front/rear
  mode selectors to `z2_bringup` launch-all. Defaults remain `adaptive` and preview
  ports remain 0; no LiveKit track/config changes.
- Source backup: `/home/nvidia/j401-gmsl/backups/parallax-20261028/`. Candidate build
  and install live only under `log/surround_vision/parallax-20261028/{build,install}`.
  Never rebuilt over mapped production libraries. No robot/chassis/arm restart.
- Nine C++ tests passed. A 25-second subscriber-only candidate launch shut down
  cleanly. It produced valid 1024x512 images with zero input/render errors and
  active correspondence protection, but failed real-time acceptance: candidate
  status FPS median ~0.98 (maximum 2.73), JPEG receive ~0.69 FPS, while the existing
  production front stream reported median ~17.97 FPS. This extra cross-process raw
  subscriber path differs from normal intra-process operation; do not attribute
  the whole drop to the seam algorithm or claim production performance from it.
- Static same-pair benchmarks exclude ROS transport/JPEG/network, with seam update
  every 10 render calls. Detailed results and exact scope are in
  `log/surround_vision/parallax-20261028/benchmark-final.json` and the primary-mode
  follow-up. They are not Quest end-to-end latency measurements.
- No system packages, drivers, Docker image, or Docker launch configuration were
  changed. A local analysis-only Python venv was created and ignored; its pinned
  packages are in local `artifacts/parallax-20261028/analysis-requirements.txt`.
- Production has NOT switched to either candidate. A deliberate deployment and
  normal coordinated restart are still required before using new mode selectors
  with the main install. The remaining goal is reliable multi-depth alignment and
  moving-scene validation; this investigation is not a complete stitching fix.

### Offline learned spatial warp comparison

- Evaluated the official StabStitch++ spatial module from
  https://github.com/nie-lang/StabStitch2 at commit
  `646dad01f2f1159aeca10bcef2fbb1416d658df7`, using the released traditional-dataset
  spatial weights. SHA256:
  `45b05fce025a8072b1b4df70b673d62ef023f5e6008df9afadbc83db5f79ec0e`.
- Ran locally on NVIDIA GB10 with an isolated PyTorch 2.14.1+cu130 venv. Downloaded
  and extracted libpython3.12-dev 3.12.3-1ubuntu0.17 under the analysis directory
  for Triton headers; CPATH applied to the evaluation process only. No global
  packages or robot/Docker dependencies were installed. Images stayed local.
- Compared room ERP crops, near-board ERP crops, calibrated perspective views,
  and raw fisheyes using official 480x360 BGR preprocessing. Complete official
  state_dict loaded strictly; only unnecessary ImageNet initialization disabled.
  This tests the spatial module and custom diagnostic compositing, not the
  complete temporal/smoothing pipeline or training/fine-tuning.
- Saved outputs retain significant board/background displacement. Soft blending
  exposes ghosting; a hard central cut clips or repeats board content. The
  off-the-shelf model was not accepted or deployed. This result does not rule out
  scene-specific training, other models, or reliable depth-aware reprojection.
- Warm spatial-network-only means were 15.8–20.9 ms across these four cases on
  GB10 (three timed warm samples each). Excludes final TPS, compositing, transport
  and encoding; this is neither a Jetson benchmark nor a real-time qualification.
- Learned output is an unconstrained mesh mosaic, not calibrated ERP. It must not
  silently inherit the current Quest ERP ray interpretation or metric overlays.
  Local `artifacts/parallax-20261028/learned/` contains images and report.json;
  evaluation script, model provenance and pinned venv requirements are saved.
- Latest bounded primary-source static run: 180 frames, mean 20.35 ms and p95
  28.75 ms for rendering only. Central board is continuous, but the peripheral
  water-stack region still has a discontinuity. No all-depth solution is claimed.

## 2026-11-17 — 前后环视按需输出 service

- 在 `zephyr_surround_vision` C++ 组件增加 `~/set_enabled`，类型
  `std_srvs/srv/SetBool`。标准节点路径为 `/surround/front/set_enabled` 和
  `/surround/back/set_enabled`。`data: true` 开启，`false` 关闭；前后独立、幂等。
- 默认 `enabled_on_start=false`。关闭时没有该拼接节点的原始图像订阅，清空配对
  缓存，跳过拼接、发布及由发布触发的编码。原始相机驱动继续运行，其他消费者
  不受控制；相机 YUYV→RGB 转换仍消耗 CPU。重开只处理新订阅收到的新配对。
- service 和渲染 timer 使用同一互斥回调组，关闭应答在最后一次发布完成后返回。
  输入回调使用互斥锁和订阅代数，丢弃旧订阅排队的回调。网络中的在途帧仍可能到达。
- status 保留约 1 Hz，新增 `enabled`；关闭为 `state=disabled`、`fps=0`、
  `render_ms=0`，累计 published 不再增长。topic 订阅不会自动打开流。
- panorama launch 增加 `enabled_on_start`；z2 launch-all/surround launch 增加并透传
  `surround_enabled_on_start` 与 `surround_back_enabled_on_start`，均默认 false。
  `enable_surround`/`enable_surround_back` 仍控制节点是否存在，不能替代运行时开关。
  预览仍默认关闭。LiveKit/Quest/HMI 的自动服务调用桥接不在本次变更中。
- 包清单/CMake 声明 std_srvs 依赖，现有 Docker 已提供，无 apt/pip 安装，无内核、
  驱动、Docker 镜像或启动配置改动。源码和 README 已更新到原工作区。
- 新增两项实际 ROS 节点/service 集成测试：默认关闭与零输入订阅、独立开关、
  幂等、恢复等待新帧、连续切换、启动显式 opt-in。与原有 11 项 renderer/pairing
  测试合计 13 项通过。测试使用进程级 ROS_DOMAIN_ID=95，未改全局 ROS 环境。
- 在独立 `log/surround_vision/flow-control-20261117/{build,install}` 编译验证，
  然后原子替换主安装引用的组件库，未原地覆盖运行进程映射的库 inode。
  原源码及库在该目录 `backup/`；参数快照 before-components.json；部署摘要 deployed.json。
- 部署异常及恢复：尝试通过组件管理服务卸载旧前视 panorama 时请求超时，原前视
  容器 PID 251527 随后以 -11 退出，launch 日志确认段错误。没有继续对后视做在线
  卸载。前视先恢复两路原始相机，再加载新 panorama；旧后视容器通过 SIGINT 正常
  停止后，仅重新启动后视相机/拼接容器。整机 launch-all PID 251446、底盘、机械臂
  和 RTC 未由本任务重启。旧版本在线卸载崩溃原因未进一步定位，不应声称已修复；
  新流控不需要卸载节点。
- 本次维护替换的环视 launch 由 supervise_recovery.py 绑定到原 launch-all 生命周期，
  原 launch-all 退出时自动关闭替换进程，避免残留占用相机。该辅助程序仅用于本次
  不中断整机的维护；之后直接使用原 z2_launch_all 即可，无需用户额外起脚本。
- 实机验证包含全关、仅前视、仅后视、全开、再次全关，均通过；关闭路接收 0 帧，
  计数稳定，开启路恢复 JPEG 输出，无输入/渲染错误。最终前后均保持 disabled。
  实机证据为 live-verification.json；当次测试容器 PID 为前视 290460、后视 300248。
- 8 秒窗口容器 CPU（一个 CPU 核=100%，含驱动与测试 JPEG 编码）：
  全开前视169.5%、后视163.1%，合计332.6%；全关前视131.5%、后视130.5%，合计261.9%。
  本次采样减少约70.7个百分点（约0.71个核），并非 CPU 归零。
  全开时测试订阅实际约5.6/6.7 JPEG fps；系统仍有较高负载，本次没有达到或声称
  20 Hz/端到端时延优化。更大的闲时 CPU 节省需要另行处理原始采集/颜色转换开销。
- 后续板子部署：同步本包以及 z2_bringup 的两个 launch 和 README，在停止使用这些库
  的相机容器后，于原 Docker 工作区执行 `colcon build --packages-select zephyr_surround_vision`。
  现有 symlink-install 的 z2 launch 源码即刻可用；普通复制安装还需重建 z2_bringup。
  正常启动仍是 `ros2 launch z2_bringup z2_launch_all.launch.py`，客户端按需调用上述 service。
- 工作区现有 `.gitignore` 的 `/src/*` 忽略了非独立 Git 仓库的 perception 源码；本次
  保留其原有仓库布局，未修改忽略规则、未提交 Git。复制到其他板子时务必包含这些源码，
  不能仅依赖工作区根仓库的 git diff。z2 子仓库其他并行工作的修改未覆盖。

- 随后观察到外部重新启动整机 launch-all（新 PID 303974）；维护替换进程随旧 launch-all
  退出自动关闭，前后均记录 clean exit。新原生环视容器 PID 304126/304129 无需辅助脚本，
  两个 set_enabled service 均可发现，实际 status 均为 enabled=false、disabled、published=0、
  fps=0。证据为 restart-verification.json。这验证了正常单 launch 默认关闭行为。

## 2026-11-17 — 补齐 GMSL 驱动源头流控

前次实现仅停止 panorama 输入订阅和拼接，四路驱动仍连续采集/转色。本次按用户纠正，
在原 `/home/nvidia/zephyr_ws/src/zephyr_common/zephyr_gmsl_camera` 增加 C++ 源头开关。

实现与文件：

- `src/gmsl_camera_node.cpp`：每个驱动的 `~/set_enabled`（std_srvs/SetBool）；
  `enabled_on_start`（默认 true）、`capture_on_demand`（默认 false）只读启动参数。
  CaptureDevice 初始化仅申请/MMAP 缓冲区；start 重新 QBUF/STREAMON，stop 检查 STREAMOFF。
  STREAMOFF 清空内核队列，重新开启不会使用旧帧。设备 FD/MMAP/独占锁保留。
- 实际采集条件为 `enabled && (!capture_on_demand || publisher.getNumSubscribers()>0)`。
  CameraPublisher 需求包括 Image（含 image_transport）和 CameraInfo。闲置时 CV 等待并每100ms
  检查需求；不 poll、不转换、不发布。服务与采集线程通过 mutex 串行访问 V4L2；关闭响应
  等待在途操作及 STREAMOFF 完成。故障锁存，停软件采集，避免忙重试/关闭其他节点。
- 驱动服务路径为 `/cameras/<front_left|front_right|back_left|back_right>/gmsl_camera/set_enabled`。
  false 优先于任何订阅需求，true 恢复许可；按需模式仍需消费者才能启动。
- `CMakeLists.txt`：相机组件补 std_srvs 目标依赖；package.xml 原本已有依赖。
- `launch/gmsl_camera.launch.py`、`launch/gmsl_surround.launch.py`：暴露两个启动参数，
  保留独立相机/标定的连续采集兼容行为。
- `zephyr_surround_vision/launch/panorama.launch.py`：创建相机时传许可 true + 按需 true。
  保留 `/surround/front|back/set_enabled` 业务入口及默认关闭；解除输入订阅后，若没有
  其他原图/CameraInfo 消费者，相应驱动自动 STREAMOFF。其他消费者仍在用时继续供图。
  外部相机（start_cameras=false）需自己启用 capture_on_demand。
- 两包 README 已更新上述协议、独立开关优先级及硬件恢复延迟。

边界：环视 service 响应保证拼接节点停止发布，不是两路硬件停流同步屏障；驱动 service
false 成功才表示该相机 STREAMOFF 完成。已发网络帧可能稍后到达。停止 V4L2 不承诺
传感器断电/整个解串器掉电。硬件 STREAMON/STREAMOFF 实测各约1.8～2秒；应异步调用。
运行负载高时服务调度也可能延迟，本轮曾有一次环视关闭响应6.2秒，其余约0.1秒。

构建与验证：

- 原容器 `zephyr_dev_24.04-aarch64-container`、admin 用户，主工作空间 colcon build
  --packages-select zephyr_gmsl_camera --symlink-install --parallel-workers 1
  --cmake-args -DCMAKE_BUILD_TYPE=Release 成功（34秒）；没有安装依赖或改 Docker 配置/镜像。
- 在独立 ROS_DOMAIN_ID=87 启动临时前后环视测试，验证默认关闭、前开后关、全开、
  驱动强制关闭优先、单相机反复启停、后开前关、全关、外部 raw 消费者保留采集并退出停流、
  三轮双组启停；27次服务调用全部成功。所有阶段无采集/渲染报错，关闭时图像计数不增长。
- 5秒 CPU 采样，100%=1核，两容器合计：初始全关3.0%，全开547.2%（包含JPEG压缩），
  流过图后全关3.2%，多轮切换后全关3.2%。这是本次同一测试进程的负载，非整机CPU。
  活跃输出受其他负载影响，测试期间约9～20Hz，不承诺本改动提升开启时的拼接帧率。
- 另测独立驱动 enabled_on_start=false / capture_on_demand=false：有订阅也保持启动关闭；
  true 恢复出图；重复 true 幂等（约0.066秒）；false 后停止出图；无订阅时连续模式仍能开启。
  5次服务调用成功，单相机容器正常退出。launch语法检查、补丁反向应用检查均通过。
- 首轮多相机测试收尾曾向整个进程组发 SIGINT，后视进程退出码 -2（信号中断），功能断言
  在收尾前已全部通过；测试工具已改为仅通知 launch 由它停止子进程，后续单相机正常退出。
  无崩溃退出 -11，无残留测试相机进程。任务开始时没有正在运行的环视容器，结束后也未额外常驻。

部署/复用：源码直接位于原 zephyr_ws，库已编入原 install，launch 为 symlink-install，
下次原来的 launch-all 直接加载新行为，不需要任何额外启动脚本。
其他同版本板子可应用下述补丁后，在既有 Docker 中正常 colcon build 相机/环视包。
未修改内核、BSP、设备树、系统服务、相机标定或 LiveKit 协议，未创建 Git 提交。

备份、补丁、构建及测试日志：`log/surround_vision/source-flow-control-20261117/`。
`backup/` 保留原相机包、原 panorama.launch.py 和旧相机动态库；
`source-flow-control.patch` 为本轮7个源码/文档文件的完整补丁；
`verification.json`、`manual-verification.json` 和对应硬件测试日志为实机证据。
本地同步副本：`zephyr_ws_integration/`，本地证据：`artifacts/source-flow-control-20261117/`。
V4L2队列启停语义核对官方文档：https://docs.kernel.org/userspace-api/media/v4l/vidioc-streamon.html

## 2026-11-17 — 移除拼接层流控，源头热待机降低首帧延迟

用户要求：zephyr_surround_vision 只按输入图像配对/拼接，移除下游开关；解释并减少开流延迟。
本节覆盖前两节中“环视服务控制订阅”和“默认关闭即STREAMOFF”的当前行为，历史记录保留。

代码变更（原 zephyr_ws / 原开发 Docker，无额外常驻脚本）：

- `zephyr_surround_vision/src/panorama_node.cpp`：删除 SetBool service、enabled_on_start 参数、
  enabled/status字段、动态订阅代次及禁用分支；两路订阅常驻。用 condition_variable 唤醒的
  单一渲染线程替代周期渲染定时器；输入回调仅校验/入队/通知，渲染在锁外，保留 rate_hz 上限，
  停顿后的首个匹配对立即处理。无新输入时只约1Hz状态更新，无重复图像输出。
  时间戳差25ms、接收年龄250ms、乱序/重复检测、有界最新匹配队列和回退处理不变。
  析构唤醒并join，ROS shutdown不再发布。状态缺输入报告stale_or_missing_input，移除enabled字段。
- 删除拼接包 std_srvs 依赖；旧 test_flow_control.cpp 删除并由 test_input_driven.cpp 替换。
  新用例覆盖常驻订阅/无service、单路不输出、错位时间戳拒绝、过期拒绝、无重复输出、
  错误frame_id拒绝、恢复即配对、关闭空闲线程；保留11项渲染/配对回归测试。
- `zephyr_gmsl_camera/src/gmsl_camera_node.cpp`：增加 idle_mode=stop|warm（独立驱动默认stop）。
  warm启动时STREAMON，禁用输出只DQBUF/QBUF归还MMAP帧，无RGB分配/转色/发布，保持硬件热。
  开启前有界丢弃ready旧帧，响应后处理新帧；不反复调用STREAMON/OFF。
  stop保留原彻底停流行为。service仍为 /cameras/<name>/gmsl_camera/set_enabled。
  新增控制请求优先标志，避免采集循环反复占锁延迟服务。启停路径增加耗时日志。
  故障时仍停止硬件并锁存，不因warm策略无限重试。
- `panorama.launch.py`：源头 enabled_on_start=false、capture_on_demand=false、idle_mode=warm。
  输入订阅不会绕过源头许可。参数为 camera_enabled_on_start=false / camera_idle_mode=warm。
- `z2_bringup/launch/surround.launch.py` / `z2_launch_all.launch.py`：改用
  surround_cameras_enabled_on_start=false、surround_back_cameras_enabled_on_start=false、
  surround_camera_idle_mode=warm。原 enable_surround / enable_surround_back 仍控制是否创建节点。
  preview继续关闭。两个独立相机launch也暴露idle_mode，保留默认stop和既有启动行为。
- 三包README更新当前API、迁移说明、热待机功耗边界、实测值。未改变其他z2修改。

调用契约：没有 /surround/front|back/set_enabled。前视需开启front_left/front_right源头service，
后视需开启back_left/back_right；建议上层并行调用一对服务。false仅保证源头完成切换，
下游可能完成已经接收的在途处理；拼接凭新鲜度/配对自然停止。warm意味着相机/链路/DMA仍耗电。
仍需新帧、配对、渲染、编码和传输；不能保证零延迟。初次launch和故障恢复仍有硬件开流时间。
未改变LiveKit/Quest桥接或编码器生命周期，不能把机器人JPEG首帧测量视为头显端到端延迟。

延迟定位及实机验证：

- 原Docker内使用现成strace/v4l2-ctl，绕过ROS捕获3帧至/dev/null。
  VIDIOC_STREAMON=1.797270s；VIDIOC_STREAMOFF=1.819122s；重复STREAMOFF仅0.000032s。
  源码计时也显示硬件启停约1790～1820ms。证据定位到本机BSP/V4L2调用内部，未修改或
  继续拆解内核等待；不推断特斯拉的内部实现。
- 原Docker构建两包成功；最终增量构建核对完成。新2项输入驱动测试+既有11项渲染测试通过。
  colcon汇总含CTest项共15项，实际gtest用例13项，无失败。
- 独立ROS_DOMAIN_ID=87实机测试：四路默认输出关闭，即使存在常驻拼接/外部原图订阅也无输出；
  前开后关、全开、后开前关、全关、四轮双组开关均通过；未检测到旧首帧回放。
  warm每台相机仅初始化STREAMON一次，反复开关无STREAMON/OFF，全部测试容器正常退出。
- enable一对源头并行发送 → 机器人端接收首张1024x512拼接JPEG（含配对/渲染/JPEG/DDS）：
  warm共10次，99.60～142.18ms，中位124.40ms；开启service响应9.66～31.13ms。
  stop共2次，1921.23～1966.26ms，中位1943.745ms；service响应1803.96～1829.84ms。
- 3秒CPU采样（100%=1核）：四路warm输出关闭，两个环视容器合计约0.33～1.0%；
  全开约421.64%，输出约20Hz。非整机指标、非功耗指标，也非所有负载下的保证值。
- z2 launch-all --show-args确认新参数默认值；所有launch语法检查和z2 git diff --check通过。

部署与记录：任务开始没有运行中的环视容器；在原install构建，无需重启整机/容器，下一次原
launch-all直接生效。测试进程已清理，未额外常驻。未安装软件/改Docker镜像、权限、系统配置、
内核、设备树或标定。没有Git提交。
证据/备份：log/surround_vision/warm-flow-20261117/（backup保留本轮前源码和两动态库）；
verification.json、live-output.log、v4l2-ioctl.trace、unit-tests.log、launch-args.log。
源码补丁：warm-flow.patch；本地同步：zephyr_ws_integration/；本地证据：artifacts/warm-flow-20261117/。
