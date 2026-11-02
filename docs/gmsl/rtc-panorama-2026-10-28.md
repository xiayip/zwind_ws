# 前视全景接入 Zephyr Teleop / LiveKit（2026-10-28）

## 对 Quest 的接口约定

| 数据源 | LiveKit名称 | 当前配置 |
|---|---|---|
| `/surround/front/image_raw` | 视频 `front` | 已启用：1024×512、目标20fps、AV1、3 Mbps配置上限、frame metadata开启 |
| `/surround/back/image_raw` | 视频 `back` | 仅预留名称，本轮未启用后视视频 |
| `/surround/front/status` | DataTrack `/surround/front/status` | 已接入，前视运行时约1 Hz发送 |
| `/surround/back/status` | DataTrack `/surround/back/status` | 已接入，后视发布ROS状态后才创建/发送 |

原wrist_camera条目保留，不以front替换它。有图像输入且RTC连接成功后才发布对应视频轨道。
只配置status不会自动创建back视频轨道；没有后视状态发布者时，不会凭空产生back状态。
当前前后投影默认均ERP（equirectangular）、水平180°/垂直90°，不是整张360°×180°球图。
两组尚未统一外参，后视旋转180°只是Quest原型的初始放置假设。

DataTrack名称保留开头的 `/`。每帧是UTF-8 JSON，沿用现有robot_state包装：
`messageType="std_msgs/msg/String"`，实际状态对象在 `packet.data.data`。
这里data.data是对象，不是需要再次JSON解析的转义字符串。
传输实现是LiveKit DataTrack，不是普通data packet。

以下是本次运行时ROS status的真实采样，按已通过回归测试的实际发送封装排列。
这是发送端载荷示例，不声称已在Quest或独立LiveKit接收端抓到该帧：

```json
{
  "messageType": "std_msgs/msg/String",
  "data": {
    "data": {
      "state": "running",
      "view": "front",
      "backend": "cpu",
      "fps": 19.998,
      "published": 3961,
      "render_ms": 17.213,
      "pair_delta_ms": 17.84,
      "oldest_input_age_at_render_ms": 26.034,
      "source_stamps_ns": [
        "1793181228713060312",
        "1793181228730900794"
      ],
      "invalid_inputs": 0,
      "out_of_order": 0,
      "render_errors": 0,
      "gain_b": 1.01,
      "adaptive_seam": true,
      "projection": "equirectangular",
      "output_width": 1024,
      "output_height": 512,
      "horizontal_fov_deg": 180.0,
      "vertical_fov_deg": 90.0,
      "reference_depth_m": 3.0,
      "opencv_threads": 4,
      "mask_rate_hz": 2.0,
      "hardware_sync_verified": false,
      "metric_bev": false,
      "calibration_status": "development_candidate"
    }
  }
}
```

所有原始字段均保留；source_stamps_ns为字符串，避免JSON消费者丢失64位精度。
Quest按到达时间判断新鲜度（可先用3秒超时），结合state字段。节点/桥断开时停止发送，
桥不会合成或回放旧状态；仅靠上一条state=running不能判断当前仍在线。

## 代码和配置变更

- `src/zephyr_teleop/teleop_rtc_cpp`：新增可选 `json_status_topics` YAML列表，订阅显式列出的String话题并转发JSON对象。
- 保留既有sendMsgToRemote封装；新增状态转发不改变控制、robot_state和视频转换路径。
- 输入限定JSON对象、不超过16 KiB；非法JSON、数组、标量和过大输入丢弃并节流记录。
- 重新初始化RTC时清理旧状态订阅，避免重复发送；首次回归测试发现了此问题，修复后通过。
- 新增C++回归测试，检查真实ROS订阅到RTC接口边界的topic、包格式、非法输入、未配置话题、重初始化及断连无缓存回放。
- `src/zephyr_z2/z2_bringup/config/teleop_rtc_input_sources.yaml` 增加front视频和前/后status映射，保留wrist_camera。
- 两个包README和本页记录协议与限制。

修改前备份：`/home/nvidia/j401-gmsl/backups/rtc-surround-20261028/`。
没有系统、Docker、内核/驱动变更，没有新安装依赖，没有Git提交或推送。
测试使用已有ament_cmake_gtest，manifest仅声明该测试依赖。

## 构建和验证

在原 `zephyr_dev_24.04-aarch64-container` 中构建 `teleop_rtc_cpp`、`z2_bringup` 通过。
修改RTC共享库前确认没有进程映射该库，避免覆盖运行中的代码。
在独立ROS_DOMAIN_ID=77执行新测试：

```bash
colcon build --packages-select teleop_rtc_cpp z2_bringup --symlink-install
ROS_DOMAIN_ID=77 colcon test --packages-select teleop_rtc_cpp --ctest-args -R test_json_status --output-on-failure
```

新测试最终1项通过、0失败；这是针对本次状态转发的回归，不是所有历史lint/测试全量运行。
包XML、配置和git whitespace另行校验。

实际LiveKit发布端已确认：

- `/teleop_bridge`连接现有token服务成功。
- 发布视频track `front`（1024×512、20fps配置、AV1）。编码器报告libaom软件编码；日志先后出现20fps和最终重连初期9fps，不能保证稳定传输20fps，也不代表Quest解码帧率或端到端延迟。
- 创建DataTrack `/surround/front/status`。
- ROS节点实际订阅了前图像和两个status话题；back视频没有配置。
- 当前服务拒绝JSON frame encoding与自定义schema encoding组合，既有LiveKitRTC回退逻辑成功发布无format metadata的数据轨道。载荷仍是上述UTF-8 JSON，Quest不应依赖schema元数据才解析。

尝试用独立只读观察者验证接收，但token服务把请求仍绑定到机器人身份。
验证程序检查JWT subject后拒绝入房，以免挤掉真实机器人连接。因此没有把发布日志冒充Quest接收验证。
没有尝试绕过token服务身份约束。后续以Quest实际订阅/解码和到达时间测量完成端到端确认。

原始验证与运行日志：`/home/nvidia/zephyr_ws/log/surround_vision/rtc-20261028/`。
包含 `front-final.log`、`rtc-launch-final.log`、`front-status-envelope.json`、观察者失败记录和验证工具。
历史失败/重试日志保留；临时的无凭据发现测试组件已卸载。

## 启动与当前运行状态

日常仍由已经集成的整机入口启动：

```bash
source install/setup.bash
ros2 launch z2_bringup z2_launch_all.launch.py
```

它启动四相机与前后ROS全景，RTC根据新配置只发送前视视频和原腕部视频；
两个status在各自发布时转发，不需要另起转发脚本。
修改YAML后需要重新加载/启动RTC组件，运行中的配置不会自动刷新。

本次调试中整机控制/原RTC已停止，仅前视拼接仍在；验证期间又检测到该独立前视进程退出。
随后重启前视，并把RTC加载到同一 `/surround_front_container`，使用同进程前图像传递。
清理了此前遗留的网页服务，最终前视launch统一拥有相机、拼接、RTC组件与8892预览。
停止此组件容器会断开RTC。启动整机launch前先停止这个独立前视会话，避免重复打开相机或重复机器人身份连接。
PID记录仍在 `log/surround_vision/bringup-20261028/front-launch.pid`。

未启动机械臂/底盘或改变运动模式。原整机launch下RTC默认仍与Orbbec同进程，
front raw跨进程到RTC的整机并发性能需另外测量，不能把本次同进程结果直接当作整机性能保证。
