# 预览默认关闭与CameraInfo空URL修复（2026-10-28）

## 行为

`z2_launch_all.launch.py`、`z2_bringup/surround.launch.py` 的前后预览端口默认均为0；
`zephyr_surround_vision/panorama.launch.py` 的preview_port默认也为0。
默认不启动HTTP服务，不写预览JPEG。ROS原图/压缩话题、LiveKit视频与状态转发不受影响。

```bash
# 默认无网页预览
ros2 launch z2_bringup z2_launch_all.launch.py
# 需要调试网页时显式开启
ros2 launch z2_bringup z2_launch_all.launch.py surround_preview_port:=8892 surround_back_preview_port:=8893
# 独立前视预览显式开启
ros2 launch zephyr_surround_vision panorama.launch.py preview_port:=8892
```

## CameraInfo报错原因与修复

CameraInfoManager在没有显式加载数据时，会在首次getCameraInfo()中延迟加载空URL对应的默认文件：
`~/.ros/camera_info/<camera_name>.yaml`。panorama原本传空URL，因此启动时产生文件不存在的错误。

驱动现在把空URL定义为“无驱动CameraInfo标定”，调用setCameraInfo()初始化内存中的未标定数据，
分辨率1920×1080，K为零、D为空；图像和CameraInfo仍使用匹配的时间戳及frame。
不会自动查找默认文件、写入空白标定文件或伪造有效内参。
显式提供的file/package URL仍会读取、验证，真实文件错误仍会报告；SetCameraInfo服务保留。
依赖默认文件自动发现的其他用法须改为显式指定camera_info_url。

panorama继续从自己独立的rig_20261028.yaml读取已复核鱼眼标定，未移除或重做这些参数。
参考上游实现：https://github.com/ros-perception/image_common/blob/jazzy/camera_info_manager/src/camera_info_manager.cpp

## 修改、备份、验证

- 修改三个launch的preview默认值、gmsl_camera_node.cpp及相关README。
- 备份：`/home/nvidia/j401-gmsl/backups/preview-camera-info-20261028/`。
- 在原Docker编译zephyr_gmsl_camera、zephyr_surround_vision、z2_bringup通过。
- 构建前确认无正在加载相机共享库的进程。
- 运行真实launch-all中的环视分支（未启动机械臂/底盘/RTC）：四路CameraInfo分辨率、frame、零K/空D检查通过；前后全景均有1024×512 RGB8图像，status正常、渲染错误为0。
- 运行日志没有Unable to open或default calibration URL错误；四路各一条INFO说明未设置驱动CameraInfo。
- 默认仅启动两个组件容器，未启动HTTP；8892/8893无监听。
- 测试定时关闭并释放相机，不留下独立预览或推流进程。
- 无系统、Docker或标定文件更改，无Git提交。

日志：`/home/nvidia/zephyr_ws/log/surround_vision/preview-camera-info-20261028/launch.log`、`outputs.json`。
新启动即生效，已运行的驱动组件需要重启；本轮未自动启动整机运动控制。
