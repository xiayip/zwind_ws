# J401 GMSL 开发记录

目标：Waveshare GMSL-2MP-Camera-A → J401 MAX96712 → V4L2 → Docker 内 ROS 2 Jazzy。

## 2026-10-09 初始状态

- 主机 nvidia@192.168.88.121；Ubuntu 24.04.4、JetPack 7.2、L4T R39.2.0、内核 6.8.12-1021-tegra；Seeed 2026-06-22 GMSL 镜像。
- 无 `/dev/video*`。运行设备树未加载 GMSL overlay。`pca954x 2-0070: probe failed`。
- 定向读取：I2C bus 2 地址 0x29 有 ACK；寄存器 0x000d 读出 0xa0。没有全总线扫描。
- CAM_VDD_EN_3V3 高；MAX96712 compatible 实际匹配 `max96724.ko`，不是同目录另一套旧的 `max96712.ko`。
- 原始启动配置、运行设备树、两种厂商 overlay 的反编译文件保存在 `logs/baseline/`。
- ROS 容器已由用户启动：`zephyr_dev_24.04-aarch64-container`。仅有交互 bash，无应用进程。
- Docker 现有配置：privileged、host network、`/dev:/dev`、`/home/nvidia:/workspaces/zephyr-dev`；本次尚未修改 Docker 配置。
- 容器已有 ROS Jazzy、v4l2_camera 0.7.1、camera_info_manager、cv_bridge。
- 不记录 sudo 密码、环境凭据或注册表认证数据；部署脚本通过标准 sudo 认证。

## 实验 01：BSP 自带 3G overlay

- 脚本：`scripts/01-enable-stock-gmsl.sh`，主机 root 执行。
- 操作：备份 extlinux 和包清单；安装 v4l-utils；调用 Jetson-IO 选择 `Seeed GMSL 1X4 3G`。
- 原始启动配置保留于 `/var/backups/j401-gmsl/stock-3g/extlinux.conf`，Jetson-IO 保留 primary 启动项。
- 此 overlay 有 1080p 模式，但传感器名称及默认模式是厂商模板，不能据此认为已完成相机适配。
- 结果：重启成功，link 3 上 MAX96717 初始化成功，nv_cam 13-001a 绑定为 /dev/video0。
- 1080p sensor_mode=1 连续采集 60 帧，单帧 4,147,200 字节，间隔约 33.333ms，无序号缺口。
- 原始相机文档标注 UYVY，但 **Seeed 当前链路写入内存的实测排列为 YUYV**：同一帧按 YUYV 解码颜色正常，按 UYVY 解码紫绿失真。保留 BSP 的 YUYV 配置，不盲改为 UYVY。
- 原始帧及对照图在 `artifacts/`；日志在 `logs/02-*`、`logs/03-*`。
- 本次主机新增包：v4l-utils、libv4l2rds0t64；未升级内核、未替换 ko。
- 重启终止了用户通过 --rm 启动的交互开发容器；后续相机使用独立容器，原开发启动脚本不改。

## 实验 02：Docker 内 ROS 发布

- 复用本机 Zephyr Jazzy 镜像作为基础，派生 `j401-gmsl-camera:jp7.2-jazzy`；Dockerfile 明确安装运行依赖。
- 容器启动先设置 sensor_mode=1，再运行 v4l2_camera，发布 `/camera/gmsl/image_raw` 和 `/camera/gmsl/camera_info`。
- Compose 仅透传视频设备，使用 video 组权限、host 网络，无 privileged；独立于原 Zephyr 开发容器。
- camera_info 尚未标定，保留为空，不填入虚构内参。
- 结果：待验证。
- 首次容器启动发现 ROS setup.bash 与 `set -u` 不兼容；调整为 source 后启用 nounset，再构建启动。未修改 ROS 安装文件。
- 第二次容器能发现话题但没有消息；内核报 `/dev/capture-vi-channel0` 不存在。Tegra 驱动从容器的设备命名空间打开内部 VI 节点，故仅透传 video0 不够。Compose 增加该 VI 节点，不扩大为 privileged。
- 派生镜像内包变化：新增 v4l-utils 1.26.1-4build3；v4l2_camera 升为 0.7.3-1noble.20260911.153510；compressed-image-transport 升为 4.0.7-1noble.20260911.193953。主机 ROS/原基础镜像未改变。
- 加入 VI 节点后 ROS 开始出图。验证脚本发现基础镜像 Python NumPy 2.2.6 与 cv_bridge 扩展的 NumPy 1.x ABI 不兼容；C++ 发布节点不受影响。验证截图改为直接写 RGB PPM，不改动 Zephyr 镜像 Python 依赖。
- ROS 原始消息验证通过：20 秒 593 帧，29.64fps，RGB8 1920×1080，时间戳递增；CameraInfo 为未标定。截图写盘会影响首次接收速度，此指标不能当成驱动丢帧率。
- 同容器 JPEG 验证通过：约 30.02fps、平均 297KB/帧。跨容器首次无消息，定位到 host 网络配合隔离 IPC 的 Fast DDS SHM 问题；相机 Compose 改为 `ipc: host`，与 Zephyr 开发启动脚本已有的 `--ipc=host` 一致。
- 跨容器 JPEG 复测通过：361 帧、30.10fps、平均 298KB/帧；订阅容器没有任何摄像头设备，只通过 DDS 收消息。
- 后续跨容器原始消息复测出现发现异常，继续将相机 PID namespace 与 Zephyr 开发容器一致设为 host，避免容器内部重复 PID 对 DDS 身份判断的影响；复测结果另见日志，不将初次 JPEG 成功等同全部通信已稳定。
- 将相机启动改为直接 exec C++ 节点，避免 `ros2 run` 包装进程占据 PID 1 时延迟转发停止信号。
- 独立相机容器已实测重启恢复。当前运行用户为 1000:1000，privileged=false，video GID=44，ROS_DOMAIN_ID=0。
- 驱动连续测试：900 帧、30.0006fps、0 序号缺口。ROS Python 订阅在截图或同时压缩时可能丢 best-effort 消息，不能将其接收计数等同驱动丢帧。
- 未验证：断电冷启动自动恢复、多相机、其他 GMSL 端口、鱼眼标定、曝光控制与硬件同步。ROS 时间戳为用户态采集时刻。
- 原来的 Zephyr Data Agent 部署不完整告警与摄像头无关，本次未改动该部署。

## 修改范围和文件

主机持久改动：两个诊断包、`/boot/extlinux/extlinux.conf` 的 JetsonIO 项与默认选择、`/var/backups/j401-gmsl/` 备份、`/home/nvidia/j401-gmsl/` 项目文件。
Jetson-IO 还可能生成其自身的 extlinux 备份，保留以便追踪。原始 dtb/dtbo、内核及 ko 文件均未改动。

Docker 持久改动：本机派生镜像 `j401-gmsl-camera:jp7.2-jazzy`、同名常驻容器。镜像包更新仅存在派生层；未推送注册表、未改原 Zephyr 工作区。
使用 `docker compose down` 停止并删除相机容器；镜像由用户按需保留。主机启动回滚脚本为 `scripts/rollback-boot.sh`。

基线版本与 SHA256 在 `logs/baseline/software-sha256.txt`；Docker 构建、每次失败和复测日志均保留。

## 最终验收（17:58）

- 最终镜像：`sha256:39314c8114489501452e69b13a2f669fbb4ced3fc260f20a4ac4593682fb82a1`。
- 独立订阅容器先订阅 JPEG、退出，再启动原始图像订阅：两项均通过（`logs/21-final-cross-container.log`）。
- JPEG：355 帧，29.64fps，平均 298,525 字节/帧，JPEG 首尾标记有效。
- 原始图像：20 秒 589 帧，29.44fps；CameraInfo 598 条，588 条与收到的图像时间戳一致；时间戳严格递增，最大间隔 67.45ms。Python best-effort 接收有少量丢帧，尚未做零丢帧或延迟性能优化。
- RGB8、1920×1080、step=5760，frame_id=`gmsl_camera_optical_frame`；最后收到的帧相对 ROS 时间约 21.6ms，此值不是曝光到发布的硬件延迟测量。
- 容器常驻运行，重启计数 0；仅 C++ 节点进程，单次采样 CPU 约 98%（约一个逻辑核）、内存约 46MiB。
- 重新运行主机安装脚本命中幂等检查，没有重复改写启动配置。Zephyr 原工作区 git status 保持干净。
- 最终配置包含 host 网络、host IPC、host PID，以及 video0/capture-vi-channel0 两个设备；没有启动特权容器。
- 本地项目与板子 `/home/nvidia/j401-gmsl/` 同步。README 包含部署、验证和回滚命令。
