# 前方双鱼眼 ROS2 拼接包（2026-10-28）

## 本轮交付

新增 `src/zephyr_perception/zephyr_surround_vision`，C++17 ROS2 Jazzy 组件
`zephyr_surround_vision::PanoramaNode`，使用原开发 Docker：
`zephyr_dev_24.04-aarch64-container`。

默认 front_left + front_right，输出 1024×512、180°×90°等距柱状全景，目标20 Hz。
这不是完整360°，不是地面BEV，也不是学习模型。后视双目可以切换 `view:=back`。
独立的 PairRenderer、PairBuffer 和 ROS2 组件便于后续扩展投影与对齐算法。

## 日常启动：只有一个 launch

在原 Docker 终端内：

```bash
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
source install/setup.bash
ros2 launch zephyr_surround_vision panorama.launch.py
```

启动前停止占用相同相机的旧 launch。此命令启动两路相机、拼接组件及预览服务；
不启动 AprilGrid 标定采集和数据保存。原始相机图像话题仍可用。
Ctrl+C 关闭此 launch 自己拥有的组件容器、相机和网页服务。

- 浏览器：<http://192.168.88.121:8892/>，约1 Hz静态JPEG刷新，仅用于检查。
- ROS图像：`/surround/front/image_raw`，RGB8，目标20 Hz。
- JPEG：`/surround/front/image_raw/compressed`，image_transport标准压缩传输。
- 有效区域：`/surround/front/valid_mask`，mono8，默认2 Hz。
- 来源区域：`/surround/front/camera_mask`，0无效/1左源/2右源，默认2 Hz。
- 接缝叠加：`/surround/front/debug/image_raw`，有订阅者才发布。
- 状态：`/surround/front/status`，JSON，含帧率、时差、处理时间、错误计数。

这些图像采用 best-effort sensor QoS。JPEG按订阅需求编码；网页另写低频预览文件。
`preview_port:=0` 同时关闭网页服务与预览JPEG落盘。网页不是Quest实时视频传输方案。

```bash
# 后方双路（若同时运行前后两个launch，要使用不同预览端口）
ros2 launch zephyr_surround_vision panorama.launch.py view:=back preview_port:=8893
# 使用已运行的相机话题
ros2 launch zephyr_surround_vision panorama.launch.py start_cameras:=false
# 加载到已存在、且启动时已source本包的ROS组件容器
ros2 launch zephyr_surround_vision panorama.launch.py start_cameras:=false target_container:=/existing_container
# 更大输出，需接受处理和传输开销增加
ros2 launch zephyr_surround_vision panorama.launch.py output_width:=1280 output_height:=640
```

载入外部组件容器时，停止本 launch 不会卸载组件，需显式卸载或停止该容器。
只修改参数文件并不会改变运行中的几何参数；参数设为只读，重启后生效。

## 图像处理及标定

1. 用本机已复核的KB4内参、双路外参建立反向LUT，完整角度使用atan2，支持超过90°的鱼眼光线。
2. 虚拟相机正前方取两光轴角平分方向；原点取两相机中心中点。默认假设场景在3 m球面。
3. 每帧OpenCV remap；重叠区估计有界亮度增益，减少曝光差。
4. 在低分辨率重叠区用颜色/边缘差异寻找纵向动态规划接缝，加时间平滑和位移限制；默认2 Hz更新。
5. 接缝附近窄带羽化；只有单路有效的区域使用该路，无观测支持区域为黑色。

`reference_depth_m:=0` 为无穷远/纯旋转模型；`seam_mode:=fixed` 可对照固定接缝。
默认3 m不是估计出的真实深度。约45 cm基线产生的近景视差、遮挡仍可能导致物体变形、重影或切断，
自适应接缝不能保证保留每个物体，valid_mask仅表达投影支持。

`config/rig_20261028.yaml` 是来自本机AprilGrid复核的开发标定快照，带源文件哈希。
前对：11个双路姿态，留出交叉误差约0.625 px；内参留出约0.192/0.358 px。
后对：16个双路姿态，交叉误差约0.495/0.860 px。此版本实际持续运行验证为前对。
快照只给渲染器使用，未把超广角参数硬塞入驱动CameraInfo或编造TF。
驱动启动时仍可能报告缺少 `~/.ros/camera_info/front_*.yaml`，其CameraInfo未标定；
渲染器从独立rig文件读取参数，两者不可混淆。
换板可复用代码，换相机或重新安装后必须更换标定，不能复制当前外参作为新机器真值。

输入配对容差25 ms、接收时间最大250 ms，队列有界，输出不复用旧输入对。
时间戳来自现有驱动软件时间，未验证硬件曝光同步。断流后停止ROS图像输出并报告状态。
全景没有普通针孔CameraInfo，也没有已标定base_link/重力TF。

## 实测与限制

环境：J401、现有JetPack7.2/R39.2、Docker ROS Jazzy、发行版OpenCV4.6和yaml-cpp0.8。
本版CPU LUT渲染，没有部署CUDA/TensorRT模型。组件容器4个executor线程，启动时设置4个OpenCV工作线程。
同进程输入使用共享ROS消息，但渲染和输出仍有内存复制，不是GPU全程零拷贝。

| 检查 | 结果 |
|---|---|
| Release编译、6个gtest用例 | 通过；colcon汇总7项（含CTest） |
| 真实前对离线拼接、接缝叠加 | 成功，图像和掩码保留 |
| 1024×512，同进程C++订阅，20秒含2秒预热 | 约19.65 fps，354帧，时间戳无重复/倒退 |
| 1024×512，独立JPEG订阅，20秒含2秒预热 | 约19.46 fps，351帧 |
| 1024×512，跨进程C++同时订阅raw/JPEG/双mask | raw约16.02、JPEG约17.69 fps，raw未达到测试17 fps门槛 |
| 1280×640，多路跨进程订阅 | 存在明显掉帧，早期结果保留，未宣称20 fps达标 |
| 最终默认入口，Python同时订阅raw/JPEG/双mask | 格式检查通过；raw约7.08、JPEG约14.49 fps，接收端掉帧明显 |
| 卸载一路相机后的断流检查 | published计数停止增长，状态stale_or_missing_input |
| 只读参数/正常SIGINT | 拒绝运行时几何修改，多次正常关闭、释放设备 |

以上是短时、本机观测，不代表端到端Quest延迟或长期可靠性。C++下游优先组成同一个组件容器，
远端观看优先压缩或后续硬件视频编码；raw跨进程并发订阅的性能限制仍需后续优化。
最终默认入口还运行了数据格式检查，详见 `final-validation/output-format-validation.json`；
该检查验证载荷、JPEG可解码、掩码、单调时间戳及配对约束，不把传输帧率当作通过条件。

板上所有运行/性能/失败日志：
`/home/nvidia/zephyr_ws/log/surround_vision/bringup-20261028/`。
包含 `cpp-transport-validation*.json`（保留未达标结果）、`jpeg-only-validation.json`、
`intra-process-validation.json`、`input-loss-validation.json`、`front-launch-final.log`。
某些ros2命令输出文件末尾含CLI退出提示，须按命令输出阅读，不都是纯JSON文件。

## 修改清单、构建与复用

- 新增本包源码、配置、单一launch、网页、README、Apache-2.0 LICENSE、.gitignore与测试。
- 工作区 `.gitignore` 原来整体忽略 `src/`；仅放行此包，其余导入仓库仍保持忽略。
- 原文件备份：`/home/nvidia/j401-gmsl/backups/panorama-20261028/workspace.gitignore.before`。
- 工作区README、GMSL文档目录及integration-log增加本页链接/记录，保留原有修改。
- 复用原Docker和原相机驱动；本轮无apt/pip安装，无Docker配置或镜像、udev、内核、设备树、权限修改。
- OpenCV线程设置仅作用于新建组件容器进程，加载到外部容器时不改全局线程设置。
- 本轮停止了旧标定预览launch，未删除标定数据；标定保存保持关闭。
- 本轮没有提交或推送Git。

```bash
cd /workspaces/zephyr-dev/zephyr_ws
source /opt/ros/jazzy/setup.bash
# 新板需先有可用的zephyr_gmsl_camera和GMSL系统驱动；已有本机可仅编译新包
colcon build --packages-up-to zephyr_surround_vision --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
source install/setup.bash
colcon test --packages-select zephyr_surround_vision
colcon test-result --test-result-base build/zephyr_surround_vision --verbose
ros2 launch zephyr_surround_vision panorama.launch.py
```

恢复旧流程时先Ctrl+C停止当前launch，再用原相机/标定launch启动；不会自动启用标定保存。
本轮交付时前方拼接保持运行，launch PID记录在Docker工作区
`log/surround_vision/bringup-20261028/front-launch.pid`；维护时先确认PID仍对应此launch再发送SIGINT。
此PID文件只是本次后台调试记录，不是日常启动依赖。

## 后续扩展

- 先评估更强的局部对齐/视差补偿，保留当前固定接缝作为基线；学习模型以后再接入，不生成未观测障碍物内容。
- 完整360°需补充两侧相机间外参和闭环检查，不能只凭前对与后对两组外参推断整车布局。
- BEV需地面/车体坐标系、相机离地高度和姿态、输出米每像素范围，增加独立投影策略。
- Quest链路需后续H.264/H.265硬件编码和低延迟传输，再测整链路时延；本包当前交付ROS拼接图像。
