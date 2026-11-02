# 前两路第二轮数据检查：2026-10-28

结论：现有图像足够用于前左、前右的首版内参和相对外参标定，可以进入前方拼接原型验证。
用户要求暂停后，已关闭保存。修复并重新启动的预览也使用 capture_enabled=false；未覆盖活动 CameraInfo 或 TF。

## 数据与结果

| 项目 | 前左 | 前右 |
|---|---:|---:|
| 累计原始 PNG | 33 | 33 |
| 原角点初筛姿态 | 24 | 31 |
| 修正角点后再次去重 | 24 | 27 |
| 用于内参拟合 | 20 | 22 |
| 留出验证姿态 | 4 | 5 |
| 拟合重投影 RMS | 0.323 px | 0.371 px |
| 留出重投影 RMS | 0.192 px | 0.358 px |

前右初筛的31个姿态中，有4个重复观测；其中1个原本进入留出集合，已移除，保持其余原始训练/留出分组不变。
再次去重使用至少4个共同标签、角点 RMS 小于25px 的规则。候选结果不是靠重复观测降低误差。

前两路共15组公共观测，重新识别、去重后11组。相对外参用9组拟合、2组留出，跨相机验证误差约0.63px。
跨相机验证时仅用前左图像估计该帧板姿态，再预测前右图像，前右留出角点没有参与这次板姿态估计。
内参固定为本轮上述结果；这属于开发阶段的留出验证，并非全新场景的独立端到端验收。

上部视野的板中心仍偏少。当前可先推进前方拼接，后续全视场验收再补上部、远距离和独立场景数据。
曝光硬同步未验证；原用户态时间戳配对不等于曝光同步证明。该检查也不包含 VR 编解码延迟或 BEV 地面标定。

## 发现并修复的问题

原采集器使用固定3px的亚像素窗口。较大标签的多边形初始角点偏差可超过窗口，部分点没有移动到真实边缘。
同一张前右留出图，在 C++ 回归检查中，旧实现 RMS 2.224px，新实现0.200px；前左1.533px降到0.194px。
原始无损 PNG 完整保留，因此已直接重新提取，无需重拍这一批。

新增内部头文件 `src/aprilgrid_corner_refinement.hpp`：按最短标签边长的16%取窗口，限制3～15px，
100次迭代、0.001px收敛精度。该范围小于实物标签20%的黑边宽度。C++采集节点调用同一实现，
manifest记录具体角点算法。新算法没有改动原图，也没有回写原始 observations.yaml。

另一个问题是旧 OpenCV fisheye 内参入口在边缘姿态初始化失败。实际数据包含超过90°的离轴射线，
本次离线诊断改用 atan2 的完整角度 KB4 投影、旋转虚拟相机初始化板姿态，再进行稳健联合优化。
前半球投影与 OpenCV 对照最大差约2.3e-13px，超过90°的投影/反投影往返检查通过。
参数在0～100°范围的角度映射保持单调。完整模型是本次诊断实现，尚未替换旧 C++ 内参命令的求解后端。
旧命令的“至少25姿态”是工具门限，不是数学最低要求；前左24姿态已有上述首轮验证结果。

## 文件、环境和验证记录

- 数据：宿主 `/home/nvidia/zephyr_ws/log/gmsl_camera/calibration-20261028/datasets/`。
- 审查记录与脚本：同目录上级的 `review-round2/`；最终候选诊断结果在 `review-round2/refined_unique/`。
- 最终内参：`front_left-bearing-diagnostic.json`、`front_right-bearing-diagnostic.json`。
  数组顺序为 fx,fy,cx,cy,k1,k2,k3,k4，像素与无量纲畸变系数；模型为 KB4_atan2_full_angle。
- 最终外参：`front-pair-extrinsic-diagnostic.json`；约定为
  `X_front_right_optical = R * X_front_left_optical + t`，t 单位米。
- 原始观察、重提取版本、初筛版本、最终去重版本均分别保留，便于追溯；没有自动部署参数。
- 可复查脚本：`refine_saved_corners.py`、`diagnose_bearing_fit.py`、`bearing_model.py`、`check_front_extrinsics.py`。
  这是离线诊断，ROS 相机与标定采集运行时仍是 C++。
- 容器原有 pip NumPy 与 apt SciPy 不兼容。本次仅在离线诊断进程中优先加载已有
  `/usr/lib/python3/dist-packages`：NumPy1.26.4、SciPy1.11.4、OpenCV4.6.0。未安装或替换任何软件包。
- 未创建新 Docker，未修改镜像、内核、设备树、系统服务、权限或 Docker 启动参数。
- C++修改前备份：`/home/nvidia/j401-gmsl/backups/calibration-20261028/aprilgrid_capture.before-refinement.cpp`。
- 构建无告警；`check_refinement_cpp.cpp` 对真实留出图复现旧实现失败、新实现通过，
  详情见 `regression-validation.json`。暂停预览重启后没有新增保存。
- 所有改动保留在原 zephyr_ws；没有提交或推送。
