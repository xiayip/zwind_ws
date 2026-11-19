# Z2 CAN 启动故障复现与恢复验证

日期：2026-11-19，时间均为 Asia/Shanghai。主机内核 `6.8.12-1021-tegra`，
容器 `zephyr_dev_24.04-aarch64-container`，ROS 2 Jazzy。

## 两个不同的阻塞点

- 底盘 `can0`：遥控器在遥控模式下关机，反馈 `control_mode=3`、
  `fault_code=0x4`。重新打开遥控器，SWB 拨到最上方完成交接后恢复；
  随后关闭遥控器，连续 8 秒保持 CAN 模式且无故障。
- 机械臂 `can1`：底盘恢复后，完整 launch 仍失败。六个关节和 OmniPicker
  都没有初始反馈，`ZephyrArmSystem` 激活失败，控制进程退出。

## can1 的直接证据

16:28:58 内核记录：

```text
mcp251xfd spi1.0 can1: IRQ handler mcp251xfd_handle_tefif() returned -22.
mcp251xfd spi1.0 can1: IRQ handler returned -22 (intf=0x3f1a0014).
```

16:55:59 实际运行用户原命令，约 5 秒内复现机械臂激活失败：

```bash
ros2 launch z2_bringup z2_launch_all.launch.py
```

抓包没有观察到 can1 报文。接口仍显示 `UP / ERROR-ACTIVE`、1 Mbps、
错误计数为零，但 RX/TX 计数停止增长，`tc -s qdisc show dev can1`
显示积压 260 帧。因此不能仅用接口 UP 或 CAN 错误计数判定通信正常。

## 本次恢复与验证

确认全部控制程序退出后，对 can1 执行 down/up，先清空积压报文，再恢复接口；
保留 1 Mbps 配置。不要在控制程序运行期间执行这个操作，也不要让旧命令排队后
直接恢复传输。

```bash
sudo ip link set dev can1 down
sudo ip link set dev can1 up
```

恢复后执行六个关节的只读参数查询，位置、run_mode、滤波电流共 18 项全部返回。
16:57:22 再次用相同的完整 launch 命令运行 90 秒，实测：

- `RangerMiniV3RealWorld`、`ZephyrArmSystem` 都处于 active。
- 底盘控制器、机械臂 MIT、位置适配器、轨迹控制器和夹爪控制器处于 active。
- MPC 按启动设计保持 inactive。
- 收到 `/joint_states`，六个关节和夹爪的位置均为有限值。
- 四个 GMSL 相机均成功启动采集；本次启动及运行阶段没有 ERROR 日志。
- can1 收发计数持续增长，发送队列积压为零，未新增驱动 IRQ 错误。

测试结束后发送 SIGINT，所有测试进程退出，没有遗留控制程序。
原始记录保存在工作区 `artifacts/can-startup-validation-20261119/` 下的
`failed-launch.log` 和 `recovered-launch.log`。

## 验证边界与剩余问题

本次验证证明接口重置恢复了通信，完整系统能够启动；尚未证明驱动问题不会复发。
当前定位到 MCP251xFD 内核驱动处理发送事件时失败，但具体触发条件仍未确认。
SPI 控制器的 runtime power 设置已经是 `on`，本次没有修改内核或安装驱动补丁，
也没有加入运行中自动重置 CAN 的逻辑。

退出测试时另有两个异常：`vr_joy_mapper` 重复调用 `rclpy.shutdown()`，
以及 `move_group` 收到 SIGINT 后段错误。二者均发生在 90 秒观察结束后的退出阶段，
本次没有修复，不能将此次记录描述为整个系统全程无错误。
