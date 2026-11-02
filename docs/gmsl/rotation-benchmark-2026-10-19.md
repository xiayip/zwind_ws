# 180°旋转方案对比 — 2026-10-19

用户确认需要旋转 180°，不是上下镜像。本轮只做离线正确性和性能对比，没有改变生产
采集代码、发布像素、话题、CameraInfo、Docker 配置、系统权限、内核或设备树。
新增内容为本记录及 log 目录中的测试源码、可执行文件与结果。

## 当前建议

- 后续若仅需要 BEV：按原始图的像素约定完成标定，让 BEV 映射直接产生期望方向的结果。
  可以将必要的 180°坐标变换合并到预计算采样映射中，避免额外生成一幅旋转图。
  这消除的是独立旋转步骤，不是说 BEV/去畸变无需计算。若还要发布正向原图，仍需处理该输出。
- 当前 CPU RGB8 ROS 接口下，以本轮测得的单帧处理延迟为目标：先用 NEON 在紧凑的 YUYV
  数据中正确重排像素，再调用已有 RGB8 转换，比先转 RGB8 再旋转更快。
- 以减少 CPU 工作量、保留 GPU 算力为目标：VIC 合并颜色转换与 180°旋转；
  下游尽量复用硬件缓冲区。普通 CPU RGB8 输出仍有复制、同步和去 alpha 的成本。
- 尚未实现/验证 V4L2 DMA-BUF 到 VIC 的直接导入，不能宣称当前采集管线已实现硬件零拷贝。
  当前驱动也没有暴露可直接使用的相机端旋转控制。

## 方法

在现有 Zephyr Docker 中以 admin 用户运行，使用已保存的真实 1920×1080 YUYV 帧。
所有缓冲区预先分配、复用，VIC 显式指定 Compute_VIC。每种实现每轮预热 8 次后运行
100 次，重复 3 轮，中间一轮逆序运行各实现。下表为三轮各自平均耗时的中位数。

分别测试 OpenCV 原始 8 线程配置和仅在诊断进程中设置的 1 线程配置。
没有在生产组件中调用 cv::setNumThreads，也没有改变板子的功耗模式或锁频。
CPU 时间取 CLOCK_PROCESS_CPUTIME_ID，是进程各线程的累计 CPU 工作量，可大于墙钟耗时。
它不是功耗测量，也不等于四路实际运行时的 CPU 百分比。

VIC 完整 RGB8 路径为：复制 YUYV 到 NvBufSurface → SyncForDevice → VIC 转换/180°旋转 →
SyncForCpu → 直接从映射的 RGBA surface 转 RGB8，避免再复制一份 RGBA 中间缓冲区。
VIC 缓冲区内的指标则只包含硬件转换和旋转，输出是 RGBA；与完整 RGB8 路径不能视为同等工作。

| 实现 | OpenCV 线程配置 | 单帧墙钟时间 ms | 单帧累计 CPU 时间 ms |
| --- | ---: | ---: | ---: |
| CPU YUYV→RGB8，不旋转（基线） | 8 | 1.038 | 5.848 |
| CPU 转 RGB8 后调用 cv::rotate | 8 | 3.980 | 9.544 |
| ARM NEON 旋转 YUYV 后转 RGB8 | 8 | 1.596 | 6.866 |
| 单线程 NEON 融合转换与旋转原型 | 8 | 4.465 | 4.458 |
| VIC 缓冲区内 YUYV→RGBA＋180° | 8 | 1.509 | 0.368 |
| VIC 含输入复制/同步及 CPU RGB8 输出 | 8 | 3.478 | 5.169 |
| CPU YUYV→RGB8，不旋转（基线） | 1 | 5.397 | 5.386 |
| CPU 转 RGB8 后调用 cv::rotate | 1 | 8.586 | 8.565 |
| ARM NEON 旋转 YUYV 后转 RGB8 | 1 | 6.051 | 6.038 |
| 单线程 NEON 融合转换与旋转原型 | 1 | 4.474 | 4.466 |
| VIC 缓冲区内 YUYV→RGBA＋180° | 1 | 1.503 | 0.349 |
| VIC 含输入复制/同步及 CPU RGB8 输出 | 1 | 3.810 | 2.648 |

在本次实现与测试条件下：默认线程配置的 NEON YUYV 重排＋转换延迟约 1.60 ms，
相比不旋转基线约 1.04 ms，多约 0.56 ms；VIC 完整 RGB8 单线程输出路径约 3.81 ms，
累计 CPU 时间约 2.65 ms；若数据保持在硬件缓冲区，VIC 转换＋180°约 1.50 ms，
累计 CPU 时间约 0.35 ms。最快与 CPU 工作量最少的选择不同。
单线程融合 NEON 原型并非本轮最快，因此没有因为它“融合了操作”就选择部署。

这些是复用保存帧的离线处理结果，不含 V4L2、ROS/DDS、四路同时运行、内存压力或 BEV
算法成本；不是对所有可能实现的全局最优证明。若要落地，应在四路实流下进一步验证。

## 正确性

YUYV 不可按任意字节或普通双通道像素直接反转：水平反向后必须保持每对像素的 U/V 归属。
原型在逆转像素对顺序时，将每对 `[Y0,U,Y1,V]` 重排为 `[Y1,U,Y0,V]`。
使用 ARM NEON table lookup 重排，输出仍为合法的 YUYV。

将 NEON YUYV 重排＋转换、融合 NEON 转换/旋转与 OpenCV 的“先转 RGB8 再旋转180°”
比较，真实帧及固定随机种子的全幅随机 YUYV 输入均逐字节一致，差异数为 0。
融合原型采用 BT.601 limited-range 定点计算，与当前 OpenCV YUYV 转换的量化一致。
本轮 VIC 使用已在上一轮完成像素对应验证的 Rotate180；本轮重点测量完整处理成本。

诊断原型固定为 1920×1080 连续 YUYV 数据，未作为通用 stride/尺寸处理实现部署。
保留原始采集图直接做 BEV 时，应使用该原图的内外参；不能随意把正向图的标定文件
套到倒置原图上。独立发布旋转后的图时也需统一 CameraInfo 和 optical-frame 约定。

## 证据及复现

主机目录：`/home/nvidia/zephyr_ws/log/gmsl_camera/rotation-benchmark-2026-10-19/`。

- `rotation-bench.cpp`：离线 C++ 对比程序，包含两个 NEON 原型。
- `report.json`：默认 OpenCV 8 线程结果。
- `report-single-thread.json`：OpenCV 1 线程结果。
- `rotation-bench INPUT_YUYV [OPENCV_THREADS]`：诊断程序用法，不是日常启动依赖。

依赖为现有 OpenCV 4.6.0、g++、ARM NEON 和 Jetson Multimedia API，没有安装新包。
测试没有打开相机设备，没有替换库，也没有启动相机常驻进程。

参考：[OpenCV 重映射](https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html)、
[NVIDIA 硬件旋转](https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/SD/Multimedia/AcceleratedGstreamer.html#video-rotation-with-gstreamer-1-0)、
[OpenCV 4.6 YUV 转换实现](https://github.com/opencv/opencv/blob/4.6.0/modules/imgproc/src/color_yuv.simd.hpp)。
