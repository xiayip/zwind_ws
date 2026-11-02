# Z2 launch-all 接入 GMSL 与前后拼接（2026-10-28）

## 启动入口

原开发Docker、原工作区，source工作区后：

```bash
ros2 launch z2_bringup z2_launch_all.launch.py
```

默认增加四路GMSL驱动与两路拼接：

| 组件容器 | 相机 | 输出 | 网页检查 |
|---|---|---|---|
| `/surround_front_container` | front_left/front_right | `/surround/front/image_raw` | 8892 |
| `/surround_back_container` | back_left/back_right | `/surround/back/image_raw` | 8893 |

两个输出各自都有 `image_raw/compressed`、`status`、掩码和debug话题。
各1024×512，ERP投影180°水平×90°垂直，目标20 Hz；尚非统一外参的完整360°。
相机由两次 `panorama.launch.py start_cameras:=true` 启动，每路只加载一次。
不要另外同时启动 `gmsl_surround.launch.py`、独立panorama或占用相同设备的标定launch。

可选参数：

- `enable_surround:=false`：不启动GMSL和拼接。
- `enable_surround_back:=false`：只启动前方两路及拼接。
- `surround_preview_port:=0 surround_back_preview_port:=0`：关闭两个网页预览及低频JPEG落盘。
- 默认预览端口8892/8893，可分别覆盖。

环视开关与 `enable_hardware` 独立；`enable_hardware:=false` 仍启动相机。
标定保存始终关闭。只启动相机/拼接时可执行：

```bash
ros2 launch z2_bringup surround.launch.py
```

## 实现与变更

独立Git仓库 `/home/nvidia/zephyr_ws/src/zephyr_z2`，起点 `4d89740`。

- 修改 `z2_bringup/launch/z2_launch_all.launch.py`：声明环视开关和预览端口，包含环视入口。
- 新增 `z2_bringup/launch/surround.launch.py`：前后各自scoped GroupAction包含已有panorama launch。
- 明确给两路传入空的 `target_container`，创建各自组件容器，防止继承RTC的 `z2_media_container`。
- 外层也隔离launch参数，前后view/port不会污染RTC参数或互相覆盖。
- package.xml添加 `zephyr_gmsl_camera` 和 `zephyr_surround_vision` 运行依赖。
- README记录默认行为、开关、设备占用和重启生效要求。

原Orbbec/RTC连接、RTC track配置和机械臂/底盘启动逻辑保持原样。
本次提供ROS全景话题，没有自动添加LiveKit视频轨道。
无需系统、Docker、驱动或依赖安装变更。无Git提交/推送。
修改前备份：`/home/nvidia/j401-gmsl/backups/z2-surround-20261028/`。

## 构建与验证

已在原Docker中执行：

```bash
colcon build --packages-select z2_bringup --symlink-install
ros2 launch z2_bringup surround.launch.py --show-args
```

构建通过。Python语法、package XML及Git whitespace检查通过。
测试脚本读取真实 `z2_launch_all.launch.py`，只选择其中的环视GroupAction执行，
未执行机械臂、底盘、RTC或行为控制分支，也未占用整机launch的运行锁。

- 实际启动4个相机组件、2个拼接组件、2个预览服务；启动按sysfs名称选设备。
- 前/后真实RGB8图像均为1024×512，frame分别为 `front_panorama_optical_frame` 和 `back_panorama_optical_frame`。
- 20秒订阅窗口各收到17个状态样本，平均节点报告输出率均约20.00 Hz；输入/渲染错误为0。
  该数字来自节点status，不是JPEG/网络传输或Quest解码帧率测量。
- 8892和8893的HTTP状态接口均返回对应view、running状态及正常计数。
- 环视分支前后所有父级launch配置完全一致；RTC `target_container=z2_media_container` 未被覆盖。
- 40秒定时停止测试，四个子进程全部clean exit，返回码0。
- 随后恢复原来的独立前视launch，验证前视能够重新打开设备。

现有驱动仍提示缺少各自CameraInfo YAML，这不是拼接加载失败；拼接组件使用独立rig文件，
驱动CameraInfo仍未导入此开发标定，详见前一版拼接记录。

日志：`/home/nvidia/zephyr_ws/log/surround_vision/z2-bringup-20261028/`：
`launch-branch.log`、`launch-branch.exit`、`output-validation.json`、`restored-front.log`。

## 交付时运行状态

现有整机launch-all未重启，以免中断机械臂/底盘/Quest会话。本次修改在下次启动时生效。
测试后的运行状态恢复为原独立前视预览；后视测试已停止。
下次重启整机时，必须先停掉这个独立前视launch，再让launch-all统一拥有四个相机。
本次独立前视的PID文件仍为Docker工作区
`log/surround_vision/bringup-20261028/front-launch.pid`；维护时先确认PID对应panorama.launch.py再发送SIGINT。
无需额外脚本参与以后的日常launch-all启动。

此轮验证了相机分支和参数隔离，没有重启整套物理机器人做全量端到端验证。
