# 2026-10-09 Zephyr 工作区整合记录

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
