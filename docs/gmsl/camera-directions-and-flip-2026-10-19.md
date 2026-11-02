# 四路方位确认与 VIC 翻转验证 — 2026-10-19

## 已应用的方位映射

用户明确确认以下对应关系，已更新到相机包 `config/surround_cameras.yaml`：

| 链路 | 传感器 sysfs 名称 | 方位 | 图像话题 | optical frame |
| --- | --- | --- | --- | --- |
| 0 | vi-output, nv_cam 13-001a | front_right | /cameras/front_right/image_raw | front_right_optical_frame |
| 1 | vi-output, nv_cam 14-001a | front_left | /cameras/front_left/image_raw | front_left_optical_frame |
| 2 | vi-output, nv_cam 15-001a | back_left | /cameras/back_left/image_raw | back_left_optical_frame |
| 3 | vi-output, nv_cam 16-001a | back_right | /cameras/back_right/image_raw | back_right_optical_frame |

每个命名空间仍有 `camera_info`、`image_raw/compressed` 和独立 camera_name。
修改了验证脚本默认名称以及包内/工作区 README，保留过去的端口编号测试记录。
本轮没有修改采集 C++ 代码、像素方向、标定参数、启动命令或 ROS QoS。
当前 symlink install 直接使用源码配置，因此无需重新编译即可应用新名称。

## 实际 ROS 验证

在现有 Zephyr Docker 中，以 admin 用户运行：

```bash
ros2 launch zephyr_gmsl_camera gmsl_surround.launch.py use_intra_process_comms:=true
```

四个组件均加载至 `/gmsl_surround_container`，四个新命名空间均收到有效 JPEG 和
时间戳匹配的 CameraInfo，frame ID 正确；默认标定文件名也分别按方位命名。
8 秒订阅分别收到 181/233/178/183 帧，约 22.90/29.14/22.50/23.31 fps。
本次**映射检查通过**；原订阅脚本的 ≥25 fps 四路性能标准仍未全部通过，未调整标准。
CameraInfo 仍未标定。SIGINT 后 launch 返回 0，四路设备释放。

## 硬件翻转实测

四个 V4L2 视频节点的控制列表都没有 vflip/hflip；微雪产品页也没有公开可直接使用的
翻转寄存器。本轮没有猜测或写入传感器/ISP 寄存器。

使用主机已有 R39.2 Multimedia API 头文件和库，编译独立 C++ 诊断程序，读取此前
保存的 `port0.yuyv` 实拍帧。明确指定 `NvBufSurfTransformCompute_VIC`，没有 GPU/CPU
自动回退。输入为 1920×1080 YUYV，输出为 RGBA，使用 NvBufSurface surface-array。

以 VIC 不翻转时的 RGBA 输出为基准，将各变换与 CPU 坐标重排逐字节比较：

| C++ API 变换 | 本机验证结果 | 与对应基准差异字节数 |
| --- | --- | ---: |
| NvBufSurfTransform_FlipY | 上下翻转 | 0 |
| NvBufSurfTransform_FlipX | 左右翻转 | 0 |
| NvBufSurfTransform_Rotate180 | 旋转 180° | 0 |

不要仅按枚举的轴向注释猜测像素变换。GStreamer `nvvidconv` 则使用自己的编号：
`flip-method=6` 为上下翻转、`flip-method=2` 为旋转 180°，与 C++ enum 数值不可混用。
参见 [NVIDIA GStreamer 文档](https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/SD/Multimedia/AcceleratedGstreamer.html#video-rotation-with-gstreamer-1-0)。

Docker admin 用户最终实测，120 次循环平均：

| 操作 | 平均时间 |
| --- | ---: |
| 缓冲区已在硬件内，VIC YUYV→RGBA＋上下翻转 | 1.52006 ms/帧 |
| CPU 输入复制＋同步＋VIC 转换/翻转＋CPU 输出复制/同步 | 3.91666 ms/帧 |
| CPU 对已有 RGBA 做倒序行复制，仅翻转 | 1.32688 ms/帧 |

CPU 项不包含色彩转换，不能直接与 VIC 组合操作比较总性能。测试重复使用一个保存帧，
不含相机取流、ROS 传输、四路并发、BEV 算法或 RGB8 输出整理成本。没有调整功耗模式或时钟。
当前生产节点依然使用 CPU MMAP→RGB8；**VIC 尚未接入生产采集链路，图像没有自动翻转**。

建议：若采用硬件方案，将色彩转换与翻转合成一次 VIC 操作，并复用硬件缓冲区。
若 BEV 后续采用 GPU remap，可考虑把方向变换合并入采样坐标，避免额外图像处理遍历。
若只需最小改动，C++ CPU 行翻转也是可行路径；并不能仅凭“硬件加速”认定端到端更快。
上下翻转与旋转 180°不同；倒装纠正通常使用后者。选择后须统一像素、CameraInfo 和标定约定。

## Docker 权限问题与已落地修复

初次 admin 调用失败，报 `NvBufSurfaceGetDeviceInfo failed` / `Couldn't create nvvic Session`，
测试程序随后在库初始化路径崩溃。主机 nvidia 用户与 Docker root 用户可运行同一程序。
检查发现 `/dev/dri/renderD128`、`renderD129` 属于主机 GID 993，admin 缺少该补充组。
本机通过 DRM render 节点访问相关硬件，没有 `/dev/nvhost-vic` 不代表 VIC 不可用。

- 在当前开发容器中将 admin 加入实际设备 GID 对应的组；GID 993 在容器名为 sgx，主机名为 render。
- 修改工作区 `docker/scripts/workspace-entrypoint.sh`：扫描 `/dev/dri/renderD*`，按实际 GID
  查找/创建组，并在 gosu 切换到普通用户之前加入该组；跳过不存在的设备及 GID 0。
- 已验证同一补齐逻辑可重复执行。新的 `docker exec -u admin` 进程能读写 render 节点，
  VIC 实测成功。既有用户终端的补充组不会自动更新，需要重新进入一个用户会话。
- `scripts/run_dev.sh` 原本就将工作区 entrypoint 挂载到容器，后续创建开发容器自动采用该修复。
  没有新增日常启动脚本，也没有要求采集组件以 root 运行。
- 排查时比较了 tegra 与 nvidia 路径下的 libnvbufsurftransform，SHA256 相同。
  最终 admin 测试使用容器原始 LD_LIBRARY_PATH 即成功，**未持久修改库路径**。
- 未修改宿主机设备权限、用户组、内核、设备树、udev 或系统服务；没有 apt 安装、
  镜像重建/推送、容器重启或 Git 提交。没有启用常驻相机进程。

## 文件与复现

备份：`/home/nvidia/j401-gmsl/backups/camera-directions-2026-10-19/`，
其中 `before.tar.gz` 保存映射/README/脚本等，`workspace-entrypoint-before.sh` 保存入口脚本原件。

记录：`/home/nvidia/zephyr_ws/log/gmsl_camera/camera-directions-2026-10-19/`。
主要证据：`mapping-check.json`、`ros-compressed-report.json`、`ros-launch.log`、
`vic-flip-admin-report.json`、`vic-flip-probe.cpp` 和 `ensure-current-render-groups.sh`。
硬件输出另存为 FlipX/FlipY/Rotate180.rgba（仅诊断，不用于替换 ROS 图像）。
性能结论以最终 admin 报告为准；早期 host/root 探索版本的计时段使用的是水平 FlipX，
当时字段名称尚未修正，不用于上表的垂直翻转性能结论。

在已经具备权限的容器中，诊断程序可用已有 g++、Multimedia API 头文件和
`-lnvbufsurface -lnvbufsurftransform` 编译；输入已有的原始 YUYV 文件，第二参数为输出目录。
该程序只用于离线验证，不是日常启动依赖。后续板子无需照抄 GID 993，入口按设备实际 GID 处理。
