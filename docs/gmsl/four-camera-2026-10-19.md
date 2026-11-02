# J401 四相机验证与变更记录 — 2026-10-19

后续更新：用户已确认 0=front_right、1=front_left、2=back_left、3=back_right，
现行话题和 Docker render 权限更新见 [方位及 VIC 验证记录](camera-directions-and-flip-2026-10-19.md)。
下文保留首次使用 port0～port3 测试时的原始记录。

## 结论与端口映射

四台 Waveshare GMSL-2MP-Camera-A 均有真实图像，支持同时采集 1920×1080 YUYV。
驱动链路为 ser_0～ser_3 → des_ch_0～des_ch_3 → CSI/VI，当前对应 video0～video3。
四路 sysfs 名称依次为 `vi-output, nv_cam 13-001a`、`14-001a`、`15-001a`、`16-001a`。
所有视频节点 bus_info 相同，不应使用 bus_info 区分相机。

安装方位尚未确认，保持 `/cameras/port0`～`/cameras/port3`；没有猜测前后左右。
实拍特征依次为：窗户/白柜、白柜/衣架、桌子/纸箱、纸箱/红架。画面均倒置，保存原样，
采集层没有翻转、裁剪或去畸变。四个 CameraInfo 均未标定，未生成 BEV、外参或 TF。

## 验证结果

- 单路测试：分别设置 sensor_mode=1 和 1920×1080 YUYV，跳过 30 帧后保存一帧。
  每路原始文件均为 4,147,200 字节，四路均成功退出。通过 Docker 内已有 OpenCV 转换检查。
- 并发 V4L2：四个流同时各采 600 帧到 /dev/null，四路日志持续报告 30.00 fps，全部退出 0。
  每次含启动的总时间约 23.67 秒。没有将此结果表述为逐序号无丢帧证明。
- Docker：使用现有 `zephyr_dev_24.04-aarch64-container`，以 admin 用户构建、运行。
  `gmsl_surround.launch.py` 成功加载四个 C++ 组件，图像、CameraInfo、JPEG 均取得有效数据。
- 启动检查：真实四路标识解析通过；故意缺失传感器和重复名称均在加载任何组件前被拒绝。
- 四路 raw 的 Python 跨进程订阅测 20 秒，四路 JPEG 测 15 秒；C++ 同进程订阅测 20 秒。

| 相机 | 同进程 RGB8 帧数（20 秒） | 同进程 C++ fps | 跨进程 Python raw fps | 跨进程 Python JPEG fps |
| --- | ---: | ---: | ---: | ---: |
| port0 | 600 | 30.07 | 10.90 | 19.92 |
| port1 | 599 | 30.05 | 11.95 | 23.80 |
| port2 | 599 | 30.06 | 12.82 | 20.24 |
| port3 | 599 | 30.08 | 7.68 | 19.11 |

同进程测试使用已构建的生产组件库，通过 rclcpp_components NodeFactory 创建四个
`GmslCameraNode`，相机及 C++ 订阅器均启用 intra-process。四路各有 599 个 CameraInfo
时间戳匹配，图像尺寸、编码、frame ID、时间戳顺序检查均通过。
该测试仅测采集及订阅，不包含 BEV 计算。用户态时间戳有调度抖动，不代表曝光同步。

跨进程 raw/JPEG 都取得有效图像，但未通过 ≥25 fps 的订阅性能标准；完整失败结果保留，
没有修改标准来使测试通过。四路 RGB8 共约 746 MB/s（不含中间件开销）。测试时板子还在
执行 IDE 索引等任务；不能仅凭本次测试将掉帧归因于某一个因素。BEV 组件宜在同一进程
使用兼容 QoS 和 intra-process，远程预览可以订阅 JPEG，实际负载下须再次测量。

初版验证脚本在写 JSON 时遇到 CameraInfo 数组元素比较产生的非原生 bool；修正显式 bool
转换后重测。原始失败日志位于 `first-verifier-attempt/`，此问题发生于诊断脚本而非相机组件。

两次四路 launch 测试均通过 SIGINT 正常退出；最终同进程测试退出 0。
收尾时四个 /dev/videoN 无进程占用，开发 Docker 保持运行，未启动相机常驻服务。

## 源码与运行环境变更

相机包位于主机 `/home/nvidia/zephyr_ws/src/zephyr_common/zephyr_gmsl_camera`，
容器对应 `/workspaces/zephyr-dev/zephyr_ws/src/zephyr_common/zephyr_gmsl_camera`。
变更前该独立仓库干净，HEAD 为 `7655c30`；本次未创建提交或推送。

- 新增 `config/surround_cameras.yaml`：四个板端传感器标识、可改名的 topic 角色及独立标定 URL。
- 新增 `launch/gmsl_surround.launch.py`：启动前解析、检查四路设备，再加载四个 C++ 组件；
  支持已有 component container、namespace 和 intra-process。运行时初始化仍由 C++ 完成。
- C++ 新增只读 `camera_name` 参数，默认节点名；四路分别设置，避免共享默认标定文件名。
  原单路 launch 默认行为不变。
- package.xml 版本 0.3.0，声明 launch 读取配置所需的 `python3-yaml`。
- 更新包内及工作区 README、工作区部署 README 和 integration-log；新增本记录。
- 新增 `scripts/gmsl/verify-surround.py`：四路并发订阅、统计和保存实拍图，仅用于诊断。
- 依赖补齐脚本增加 python3-yaml 检查。容器内该依赖已经安装，本次没有 apt 安装或升级。
- 只构建 `zephyr_gmsl_camera`，没有重建其他工作区包。编译与 Git diff 空白检查通过。
- 临时 C++ 性能测试源文件、构建目录和程序保存在本次 log 目录的 `intra-process-probe/`；
  它加载生产组件库，未替换生产节点，未加入日常启动流程。

主机只改变了四路传感器的运行时模式和格式（mode 0 → mode 1，1080p），未修改内核、
设备树、extlinux、权限、udev、系统服务或 shell 配置，未重启板子。
继续使用既有 1×4 3G GMSL overlay。未新建/重启 Docker、修改镜像或设备映射，未推送镜像。

修改前备份：`/home/nvidia/j401-gmsl/backups/four-camera-2026-10-19/`，
含 `package-before.tar.gz`（包含原 Git）、`workspace-docs-before.tar.gz` 和
`workspace-README-before.md`。
运行与构建记录：`/home/nvidia/zephyr_ws/log/gmsl_camera/four-camera-2026-10-19/`，
包含原始 YUYV、JPEG、ROS PPM/JPEG、media 拓扑、逐路/并发采集日志、订阅统计和测试源文件。

## 后续启动与复制到其他板子

已有 Zephyr 开发容器，新终端按 ROS 标准加载工作区后执行一个 launch：

```bash
source /workspaces/zephyr-dev/zephyr_ws/install/setup.bash
ros2 launch zephyr_gmsl_camera gmsl_surround.launch.py use_intra_process_comms:=true
```

四路图像为 `/cameras/portN/image_raw`，CameraInfo 为 `/cameras/portN/camera_info`，
JPEG 为 `/cameras/portN/image_raw/compressed`。后续 BEV 节点需启用 intra-process，
并加载到同一个 `/gmsl_surround_container`。也可用 `target_container` 指定机器人总容器。

其他同型号板子沿用现有一次性主机 setup 脚本和 Docker 启动流程。确保四路视频/VI 设备
与 sysfs 可访问，复制相机包并编译后，按新板子媒体拓扑与实拍内容核对 YAML 中的端口标识。
更换物理相机/线缆后必须重新核对，标识绑定板端链路而非相机序列号。
确认实际安装位置后将 name 改为 front_left/front_right/back_left/back_right，分别设置
camera_info_url；以同一原图坐标约定完成鱼眼内参、地面外参标定后再接 BEV。

参考：[Seeed 多相机 BEV 教程](https://github.com/Seeed-Projects/mobile-robot-full-stack-course/blob/main/docs/M02-Fundamentals-of-Vision-Systems/2.4_Multi-Camera_BEV_Stitching/README_zh_CN.md)。
其 equidistant 标定与四个正方向相机配置需按实际安装调整，当前未移植该 BEV 包。
