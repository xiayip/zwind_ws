# J401 Waveshare GMSL camera

相机发布运行在现有 `zephyr_dev_24.04-aarch64-container` 内，源码和配置属于本工作区：
`src/zephyr_common/zephyr_gmsl_camera/`。不需要独立相机 Docker 容器。

## 日常启动

四相机环视入口（2026-10-19）：

```bash
ros2 launch zephyr_gmsl_camera gmsl_surround.launch.py
```

四个 C++ 组件在同一个 ROS component container 中运行。用户已确认端口 0/1/2/3
依次为 front_right/front_left/back_left/back_right，对应 `/cameras/<方位>/image_raw`，
并发布独立的 `camera_info` 和 `image_raw/compressed`。相机包
`config/surround_cameras.yaml` 保存该映射及各路标定 URL。
详细映射、测试结果和操作记录见 [四相机验证记录](four-camera-2026-10-19.md)。
启动前会检查四个传感器端口；全部存在才加载，避免缺一路时话题发生错配。
Docker 需映射四路视频设备及 VI 设备，并可读取 `/sys/class/video4linux`。
现有开发容器已经满足，本次没有更改 Docker 配置或镜像。

以下单相机入口仍可独立使用；不要与四路入口同时占用同一个设备。

在已经编译、加载工作区环境的 Zephyr 开发容器终端中，只运行一个 launch：

```bash
ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py
```

launch 创建 ROS component container 并加载 `zephyr_gmsl_camera::GmslCameraNode`。
C++ 组件自动检查设备、配置采集模式、采集并发布原始图像、CameraInfo、JPEG 话题。
按 Ctrl+C 关闭整个 launch 并释放相机。日志使用 ROS launch 的标准日志目录，启动时会打印位置。
首次编译、新终端环境加载、参数和加入机器人总 launch 的方法见
[相机包 README](../../src/zephyr_common/zephyr_gmsl_camera/README.md)。

加载到已有 ROS component container：

```bash
ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py \
  target_container:=/robot_container use_intra_process_comms:=true
```

此模式中相机生命周期归目标容器管理，使用 `ros2 component unload` 单独卸载。
组件的初始化、V4L2 ioctl、MMAP、颜色转换和资源释放均为 C++，运行时不调用 shell 工具。

可配置设备、命名空间、坐标系和标定文件：

```bash
ros2 launch zephyr_gmsl_camera gmsl_camera.launch.py \
  video_device:=/dev/video0 camera_namespace:=/camera/gmsl \
  frame_id:=gmsl_camera_optical_frame camera_info_url:=file:///path/to/calibration.yaml
```

默认发布 `/camera/gmsl/image_raw`（RGB8、1080p）、`/camera/gmsl/camera_info`、
`/camera/gmsl/image_raw/compressed`（JPEG）。原始图像 QoS 为 best effort。
未提供标定文件时 CameraInfo 保持未标定，不含虚构内参；相机安装位姿及 TF 未在这里定义。
图像时间戳为 C++ 节点用户态采集处理时间，不能视为已校准的曝光时刻。

首次编译相机包：

```bash
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
colcon build --symlink-install --packages-select zephyr_gmsl_camera
source install/setup.bash
```

新终端需要加载 `source /workspaces/zephyr-dev/zephyr_ws/install/setup.bash`，
如终端已自动加载工作区则无需重复。旧 `scripts/gmsl_camera.sh` 仅保留作调试档案，不参与日常启动。

## 新板子的一次性部署

主机需要 Seeed J401 Robotics GMSL BSP：JetPack 7.2 / R39.2.0 / 6.8.12-1021-tegra。
在主机（非 Docker）启用并保留原启动配置：

```bash
cd ~/zephyr_ws
sudo bash scripts/startup/setup_j401_gmsl.sh
sudo reboot
```

该脚本只修改 GMSL 启动配置并安装诊断工具，**不会自动执行重启**。
在所有机器人上执行的 `setup_device_all.sh` 不会自动选择这个板型专属配置。

进入开发容器后，旧版拉取镜像需一次性补依赖：

```bash
cd /workspaces/zephyr-dev/zephyr_ws
bash scripts/install_gmsl_dependencies.sh
```

Dockerfile.zephyr 中保留 v4l-utils 用于诊断；C++ 组件运行时不依赖此命令。
ROS 层原本就包含 rclcpp_components、image_transport、camera_info_manager 和 OpenCV。
JPEG 由 compressed_image_transport 按需提供；旧 v4l2_camera 软件包保留但不再用于本包采集。
本次没有向注册表推送新镜像；对旧镜像可运行依赖补齐脚本检查并安装缺失项。
补齐脚本只安装缺失包，不升级已安装 ROS 包。也可以按现有工作区流程本地构建镜像。
这些步骤仅用于部署或重建缺少依赖的旧镜像；完成后按上面的包编译和单 launch 方式运行。
运行时 launch 不执行 apt、不切换主机启动配置，也不启动其他 Docker 容器。

现有 `scripts/run_dev.sh` 已提供 `/dev:/dev`、host 网络、host IPC、Jetson host PID，
因此无需新增特权参数。Tegra 采集除了 video0 还需要 `/dev/capture-vi-channel0`。
用户需有 video 组权限，现有 entrypoint 已处理。ROS_DOMAIN_ID 应与其他节点保持一致。

## 验证及回滚

```bash
# 在开发容器中订阅实际消息；无需 Python cv_bridge/NumPy 兼容改动
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
python3 scripts/gmsl/verify-ros.py --seconds 20
python3 scripts/gmsl/verify-compressed.py
```

测试脚本默认订阅 `/camera/gmsl`。主机 V4L2 检查应先停止 ROS 采集，避免设备争用。
已验证单相机在第 4 路（link 3），应用数据格式 YUYV、sensor_mode=1、1920×1080@30fps。
微雪文档所述 UYVY 不可直接套用本机内存字节顺序。其他端口、多相机和冷启动恢复尚需验证。

在运行 launch 的终端按 Ctrl+C 停止发布。主机启动配置回滚：

```bash
sudo bash scripts/startup/rollback_j401_gmsl.sh
sudo reboot
```

首次驱动调试记录已随工作区保存在 `docs/gmsl/bringup-history.md`。
本次整合记录在 `docs/gmsl/integration-log.md`。原独立项目 `~/j401-gmsl` 保留作为调试档案；
独立容器被停止且取消自动重启，不应与本工作区同时开启。

## 双鱼眼拼接入口（2026-10-28）

在原Docker中停止占用前两路的旧launch后，执行：

```bash
ros2 launch zephyr_surround_vision panorama.launch.py
```

一次启动相机和C++拼接组件；网页默认关闭，需显式传入 `preview_port:=8892` 开启。标定保存保持关闭。
输出 `/surround/front/image_raw` 及 `/surround/front/image_raw/compressed`；
网页 <http://192.168.88.121:8892/>。默认1024×512、目标20 Hz，近景视差仍有限制。
详见[拼接实现及实测记录](panorama-package-2026-10-28.md)和
[包README](../../src/zephyr_perception/zephyr_surround_vision/README.md)。

## Z2 整机入口（2026-10-28）

`ros2 launch z2_bringup z2_launch_all.launch.py` 默认包含四路GMSL相机和前/后拼接，
无需另起相机或panorama。参数开关、当前运行状态和验证见
[Z2接入记录](z2-bringup-integration-2026-10-28.md)。

## Quest / LiveKit 前视接入（2026-10-28）

前视视频track为 `front`；`back`仅预留、暂不发送后视视频。前后status配置为同名
DataTrack `/surround/front/status`、`/surround/back/status`，在各自ROS状态发布时发送。
JSON封装、实测和完整示例见[RTC接入记录](rtc-panorama-2026-10-28.md)。
