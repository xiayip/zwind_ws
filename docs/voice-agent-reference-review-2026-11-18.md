# 配送语音 Agent 初版评估与接入方向

日期：2026-11-18。参考目录：`src/tmp/voice-json-agent_full_20261114`。
本轮检查当前源码与测试，备份文件及历史订单不作为实现依据。参考目录和远端
Agent 源码均未修改，没有启动在线会话或提交真实订单。

## 结论与复用范围

适合借鉴业务拆分，不适合直接复制部署。保留“语义提取不修改订单、Python
状态机控制字段更新和确认”的思路；手机号分段、替换过程保留旧值、错误输入
原子回滚等逻辑也有参考价值。端侧音频继续使用已经验收过插话的 ROS/ReSpeaker
配置，不再并行运行参考项目的 sounddevice/Speex 客户端。

当前参考版本与服务器已有版本是两个不同的原型：

| 项目 | 参考目录 | 现有服务器项目 |
| --- | --- | --- |
| Agent SDK 锁定版本 | 1.8.10 | 1.3.12（此前核对 uv.lock） |
| 模型路径 | LiveKit Inference：STT + 语义 LLM + TTS | 已配置 xAI Realtime，也有 OpenAI pipeline 分支 |
| 业务 | 楼号、房间、手机号收集；本地 JSON 文件 | 通用问答、搜索；没有订单业务 |
| 设备客户端 | 直接打开 sounddevice，另做 Speex AEC | 可复用工作区 ROS/LiveKit 桥 |
| 订单回执 | 自建 ORD 编号及本地文件 | 尚无 |

LiveKit Inference 使用 LiveKit Cloud 凭据，不能把自托管 RTC Server 的凭据当成
Cloud 模型服务凭据。自托管部署应配置具体模型提供商插件及凭据。
参考版的 `on_user_turn_completed` 控制流程迁移到 realtime 模型时，也需要重新
验证 turn detection；官方要求由 Agent 检测轮次才能使用此 hook，不能只替换 LLM。

依据：[Inference 认证](https://docs.livekit.io/agents/models/inference/#authentication)、
[轮次完成 hook](https://docs.livekit.io/agents/logic/nodes/#on-user-turn-completed)。

## 必须补齐的业务边界

1. **目的地目录**：参考模型只有纯数字 building / room，没有 floor。
   HMI 已有 `building_id / floor_id / room_id` 及合法目录。需要将“A 座三楼三零五”
   映射到当前站点中的真实条目，不能生成任意地址，也不能仅凭房号猜楼层。
2. **确认与改口**：`agent.py` 中收到“要修改”但尚无新值时，只返回追问，仍可能
   保持 CONFIRMING；`confirm` 分支也没有检查 uncertain_fields。
   新实现应记录当前追问字段，修改意图立即使之前的确认失效，确认绑定具体草稿版本。
   字段齐全与用户已确认是不同状态；播报被打断不能自动视为确认。
3. **真实提交与幂等**：本地 JSON 保存成功不是 HMI/订单平台接单成功。
   应复用 HMI 的 UUID、目录验证、机器人接单状态、幂等提交、结果未知后的同 ID 恢复，
   收到真实回执才能播报成功。语音和触屏不能形成各自独立的订单。
4. **会话上下文**：语义解析只带字段快照，没有上一次实际问题；单独的数字或“可以”
   在不同追问后的含义不同，需要传入待回答问题/字段并测试真实模型。
5. **多设备与状态同步**：Agent 会话绑定指定机器人和参与者；草稿携带 session_id、
   revision，通过受控桥接同步到本机 HMI。远端服务器的 localhost 不是 Jetson。
6. **模型与设备配置**：固定设备编号、Cloud Inference 模型名和插话阈值不直接搬用。
   参考客户端也在设备端签发 token；正式客户端沿用现有 token 服务，不复制服务端密钥。
7. **日志**：参考实现记录完整用户原话、手机号和订单 JSON；正式运行应默认脱敏，
   不将测试录音和历史订单文件混入源码仓库。

## 建议实现分工

- **Jetson 音频层**：`/voice_audio/clean` → 现有 RTC 桥麦克风轨道；
  Agent 下行 → `/voice_audio/out` → ReSpeaker，实际 played 继续给 AEC。
- **服务端 Agent**：中文听说、目的地候选解析、追问和草稿工具；模型供应商独立配置。
- **本机 HMI/订单层**：拥有同一份草稿及 revision，提供站点目录、草稿更新、确认、取消、
  提交与回执；沿用现有订单服务规则。
- **接入协议**：先打通指定会话的草稿同步/读取回执，再将语音确认接入同一提交入口。
  第一阶段使用 mock 订单，覆盖正常流程、改口、重复确认、超时恢复、断线重连。

第一批验收场景：

- “送到 A 座三楼三零五”，手机号分三段，逐项复述且目录映射正确。
- “对，不过房间改成三零六”，必须修改并重新确认，不能按旧草稿提交。
- “我要改手机号”后说“好”，不能提交尚未改完的旧号码。
- 用户提供目录外地址、含糊楼层或不完整号码时追问，不猜值。
- 重复确认只形成一笔订单；提交超时明确表示结果待核实，同 ID 查询/恢复。
- 机器人只播放自身语音时不生成字段更新；真人插话仍能更改字段。

## 检查范围与证据

业务单元测试与 SDK/语音测试需要区分：即使纯 Python 测试通过，也不能证明
中文识别、模型意图判断、打断或 LiveKit 房间收发已通过。现有测试主要验证
状态更新、JSON 保存及语义结果格式；`test_natural_delivery.py` 的输入也是
结构化字段，不是自然语言模型会话。

本轮测试输出保存于 `artifacts/agent-review-2026-11-18/`。

实际验证结果：

- 在容器隔离依赖环境中使用 uv 和参考锁定的 `livekit-agents==1.8.10` 运行现有测试：
  **31 passed**。没有更改参考工程的 lock 或安装到生产运行环境。
- 使用真实 SDK 导入原始 Agent，在临时目录和合成电话号码上直接驱动业务处理：
  `correct_information` 且 updates 为空后仍为 `confirming`；后续 `confirm`
  会使用旧信息进入 `completed`。
- `_validate_result` 接受 `confirm` 同时包含“不确定电话号码”的结构；Agent 随后
  进入 `completed`。说明不能只依赖模型正确选择 intent，业务层必须检查不确定性。
- 两个复现都没有请求模型，是确定性的业务边界检查；不能据此声称真实模型一定会
  对某句话输出上述意图。临时 JSON 随测试目录退出清理，没有创建真实配送订单。
- 复现脚本为 `artifacts/agent-review-2026-11-18/reproduce_confirmation.py`，
  对应输出为 `confirmation-reproduction.log`。纯测试总输出为 `pytest.log`。
