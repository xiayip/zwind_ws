# 2026-10-28 AprilGrid 标定准备与第一轮采集

用户实测型号 AprilGrid-600-5x5-80-24 的标签黑框 80 mm、净间距 24 mm。
实拍确认 tag36h11、双层黑边、编号从左下角 0 向右再向上排列至 24。
OpenCV 角点序为右下、左下、左上、右上；板坐标 x 右、y 上、z 出板，米制。
首次前左识别24个标签、前右11个。新 Orbbec 占用 video0～9，GMSL 为 video10～13。

## 修改记录

- 修改前独立相机仓库 HEAD 为 34473fe；没有提交或推送。备份位于
  `/home/nvidia/j401-gmsl/backups/calibration-20261028/package-before.tar.gz`。
- 新增 C++ AprilGrid 采集组件、单一标定 launch、实物参数、网页预览与 C++ 内参候选求解器。
- 继续使用现有 `zephyr_dev_24.04-aarch64-container`；没有创建其他 Docker。
- 同一 launch 自动启动 Python 标准库 http.server（LAN 8891）展示状态；图像采集和 ROS 发布均为 C++。
- 新增依赖 std_msgs/std_srvs、OpenCV aruco/imgcodecs/calib3d。现有容器均具备，未执行 apt 安装。
- 未修改镜像、内核、设备树、启动项、系统服务、Docker 参数或设备权限。
- 幂等依赖脚本增加 std-msgs/std-srvs/libopencv-contrib-dev 检查。更新 README、.gitignore，安装时排除 __pycache__。
- 首轮门限2px/连续3次对手持偏严，默认调整至4px/连续2次；清晰度、足量标签、新姿态筛选保留。
- 调整时仅重载采集组件，产生新 session；旧数据不覆盖。内参工具支持跨 session 去重。
- 用户表示首轮完成后调用 set_capture(false)，随后 clean SIGINT 停止旧 launch；预览以 capture_enabled=false 重启。

## 数据审计

数据在宿主 `/home/nvidia/zephyr_ws/log/gmsl_camera/calibration-20261028/datasets/`，
Docker 对应 `/workspaces/zephyr-dev/zephyr_ws/log/gmsl_camera/calibration-20261028/datasets/`。

| 方位 | 保存张数 | 去重姿态数 | 角点凸包覆盖 |
|---|---:|---:|---:|
| 前左 | 14 | 11 | 50.6% |
| 前右 | 8 | 7 | 38.5% |
| 后左 | 2 | 2 | 12.4% |
| 后右 | 1 | 1 | 3.8% |

前两路有5组公共观测，每组6～23个共同标签，用户态时间戳差4.7～10.7ms。
这些不是曝光硬同步的证明。两路上部数据明显不足，当前不能可靠求解。
角点覆盖并不等于姿态丰富度；没有生成或部署实机 K/D、外参、拼接参数。

## 验证与限制

- C++ 编译、实物识别、无损原图与 YAML 保存、跳过重复姿态、暂停服务通过。
- 旧 launch SIGINT 后 clean exit，再次启动相机通过。
- 内参合成测试：40姿态、已知K/D加0.05px噪声，三组初值均收敛，训练0.0701px、留出0.0685px。
  这不是实际相机的标定误差。少于25个不同姿态时拒绝求解。
- ROS 时间戳为用户态；硬件曝光同步未验证，采集时板与车体必须停稳。
- 目前完成采集和内参候选工具；相对外参、车体坐标、全视场验证、前方拼接、BEV待后续。
- 编译、原始数据、审计与运行日志位于 `log/gmsl_camera/calibration-20261028/`。
- 最终构建无编译告警；依赖补齐脚本确认全部已安装，git diff --check 通过。
- 四路真实数据不足的拒绝测试均返回1，未创建任何结果目录；记录为 insufficient-data-test.json。
- 浏览器实测预览为暂停状态、历史累计14/8/2/1正确，图像与标签识别持续刷新；新 session 保持0张。
- 最终保留暂停预览，PID文件为 `log/gmsl_camera/calibration-20261028/preview-launch.pid`，
  相机仍由该 launch 占用。继续调用 set_capture(true)；停止可在 Docker 内向该 PID 发送 SIGINT。

下一轮优先补前左约20个、前右约25个姿态，重点抬高到画面上方并改变距离和倾角；
前方重叠区再补10～15组。每次停稳3～5秒，以网页计数增加或提示音为准。

参考：[Kalibr 目标定义](https://github.com/ethz-asl/kalibr/wiki/calibration-targets)、
[OpenCV fisheye](https://docs.opencv.org/4.6.0/db/d58/group__calib3d__fisheye.html)。
