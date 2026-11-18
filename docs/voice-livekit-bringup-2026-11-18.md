# Jetson 音频检查与 LiveKit 语音助手接入

检查日期：2026-11-18（Asia/Shanghai）。目标：现场用户与机器人对话，生成配送订单信息，作为 HMI 的语音入口；最终完成 LiveKit 服务端语音助手配置及端到端验证。

**最新状态**：ReSpeaker Lite 已成功枚举，录音有非零信号；用户已确认直接硬件播放的四声提示音可听见，主板喇叭正常出声。默认输入/输出已切换为 ReSpeaker，播放音量调整至 80%。下方早期检查结果保留排查过程。

AEC 实时优化已完成，用户试听确认插话清楚完整、播报残留可接受；当前可作为 LiveKit 联调基线。首轮播放残留及 ASR 误触发仍需在线验证，详见 [AEC 实测记录](aec-validation-2026-11-18.md)。

## 当前实测

设备为 NVIDIA Jetson Orin Nano Seeed reComputer classic Robotics，Ubuntu 24.04，内核 6.8.12-1021-tegra。宿主机使用 PipeWire 1.0.5，WirePlumber 正常运行。

| 项目 | 实测结果 | 判断 |
| --- | --- | --- |
| 声卡 | HDA 和 APE；未枚举到 USB 音频设备 | USB 麦克风/音箱尚未被系统识别 |
| 默认播放 | `alsa_output.platform-sound.analog-stereo`，APE device 0，40%，未静音 | 软件通道存在，物理出声待现场确认 |
| HDMI 播放 | `alsa_output.platform-3510000.hda.HiFi__hw_HDA_3__sink`，WaveShsare089 | 显示器报告支持双声道 LPCM |
| 默认录音 | `alsa_input.platform-sound.analog-stereo`，APE device 0，100%，未静音 | 通道可打开，但未获得有效声音 |
| PipeWire 录音 | 5 秒墙钟窗口内收到 3.072 秒、48 kHz、双声道 S16 样本，全部为零 | 不是可用的人声录音；退出码 124 来自主动限时 |
| ALSA 直接录音 | `hw:APE,0`，48 kHz、双声道 S32，3 秒/144000 帧，成功退出，全部为零 | 绕过 PipeWire 后仍无有效输入 |
| 播放测试 | 板载、HDMI 依次播放各 2 秒的低幅度提示音，均成功退出 | 仅证明播放调用完成，不能据此确认喇叭实际出声 |

测试没有修改默认设备、音量、混音器路由或系统服务。现有路由为 ADMAIF1 ↔ I2S2、ADMAIF2 ↔ I2S4；路由配置本身不能证明有真实麦克风或 codec 接入。输入全零的具体原因尚未确定，需结合接线、codec 和所选 I2S 通道检查。

原始结果位于 `artifacts/audio-check-2026-11-18/result.json`；`capture.wav` 是此次全零录音，`test-tone.wav` 是两声测试音。这里只测试了默认板载采集口，未对全部 ADMAIF 接口逐个测试。

## 已有工程接入点

- `src/zephyr_teleop/teleop_rtc_cpp` 已实现 `/audio` → LiveKit `microphone` 音轨，以及远端音频 → `audio_play`；消息类型为 `audio_common_msgs/msg/AudioStamped`。仍需启动并验证实际采集和播放节点。
- `src/zephyr_common/audio_common` 提供音频相关组件；本次检查的 Z2 launch 未发现音频采集/播放启动项。当前容器 ROS 查询未发现名称含 audio/voice 的话题，或名称含 audio/rtc/hmi 的节点。该查询不能排除其他 ROS domain 中的实例。
- HMI 的语音交互尚未接入。`zephyr_hmi/server.py` 当前返回 `Permissions-Policy: microphone=()`，如果选择浏览器直接采集，需要专门调整权限与前端接入。
- HMI 已有订单目录、号码校验、确认和幂等提交逻辑。提交字段为 UUID、`building_id`、`floor_id`、`room_id`、`phone`，机器人身份和取件点由服务端配置决定。语音生成的目的地应映射至现有目录。
- HMI 本机接口仅监听 loopback，服务端 Agent 不能直接访问自己的 `127.0.0.1` 来调用 Jetson HMI。需要明确的消息回传/本机桥接，不能仅配置一个远端 HTTP 地址就认为已打通。
- 本机已有机器人 token 服务配置，可供 RTC 客户端使用；已检查的 `/etc/zephyr/robot.env` 未配置 LiveKit Agent 所需的 `LIVEKIT_URL`、`LIVEKIT_API_KEY`、`LIVEKIT_API_SECRET`。后续用户已提供服务器入口，见下方复查。

## 分阶段推进

1. **本机收放声**：确认麦克风/音箱型号与接线；获得有效人声录音并回放，现场确认音量和音质。设备选定前不盲目切换 I2S 路由。
2. **RTC 双向音频**：优先评估复用现有 ROS/LiveKit 音频桥。启动采集和播放节点，核对格式、采样率、缓冲与实际消息流；验证远端能听到 Jetson、Jetson 能播放远端声音。确定单一音频采集/播放所有者，避免 HMI 浏览器和 ROS 同时重复播放。验证回声消除与打断。
3. **服务端助手**：以独立 Agent 进程/容器连接目标 LiveKit Server，配置中文 STT、LLM、TTS 或合适的实时语音模型。明确 agent name、room、机器人 participant identity 和订阅策略；使用显式 dispatch 控制会话启动，避免旁听所有机器人房间。
4. **HMI 订单信息**：Agent 追问缺失字段，将结构化草稿及识别文本回传 HMI；沿用目录和号码校验，让用户确认后走既有幂等订单接口。先用 mock orders 验证，不把识别文本直接当作成功订单回执。
5. **终点验收**：服务器 Agent 能注册并按需入房；中文对话双向可听；HMI 展示正确订单草稿；确认、取消、改口、断线恢复及重复确认行为可验证。真正订单成功以订单服务回执为准。

服务端入口及已有模型配置已在后续复查中确认。无需把密钥粘贴到聊天或提交到仓库。

## ReSpeaker Lite 与服务器复查

用户确认实际设备为 **USB 连接的 ReSpeaker Lite**，正在检查接口和数据线。再次检查 USB、ALSA、PipeWire，均未发现 ReSpeaker/Seeed/XMOS 设备，也未发现 `2886` 厂商设备。因此之前板载 APE 的录音结果不代表 ReSpeaker 的麦克风测试结果。提示音未获得现场听音确认。

USB 接法需使用 ReSpeaker 主板的 XMOS USB-C 接口（靠近 3.5 mm 音频口），并使用数据线。USB 声卡模式需要 USB 固件；XIAO USB 接口及 I2S 固件用途不同。目前不能远程确认线缆、接口或板上固件，不应仅凭未枚举就判定硬件损坏，也没有进行固件刷写。

- [Seeed ReSpeaker Lite 入门说明](https://wiki.seeedstudio.com/reSpeaker_usb_v3/)
- [Seeed ReSpeaker Lite FAQ](https://wiki.seeedstudio.com/respeaker_lite_faq/)

已通过用户提供的 `ssh root@118.196.31.226` 成功登录。远端只做了读取和连通性检查，未修改服务或部署文件：

| 项目 | 实际状态 |
| --- | --- |
| LiveKit | `/opt/livekit`，容器版本 `v1.13.11`，正在运行 |
| 公网地址 | `wss://rtc.zwind-robot.com`；对应 HTTPS 探测返回 200 |
| 已有助手 | `/root/agent-starter-python`，没有运行的 Agent 容器或匹配的 Python 进程 |
| 已有模型配置 | `.env.local` 选择 `BACKEND_MODE=xai_realtime`、`XAI_VOICE=Ara` |
| SDK 锁定版本 | `livekit-agents`/`livekit-plugins-xai` 为 `1.3.12`；`livekit-api` 为 `1.1.0` |
| LiveKit 凭据 | 助手环境文件的 URL/API key/secret 与运行中的 token server 一致，仅比对未输出值 |
| 模型网络 | 直接访问 xAI/OpenAI 返回 Network is unreachable；经现有 `127.0.0.1:7890` Mihomo 代理，携带已有凭据访问两家的 `/v1/models` 均返回 HTTP 200 |

`/v1/models` 成功只证明该接口的连通性和认证通过，不等于实时语音 WebSocket、特定模型权限、余额或语音生成已通过。

已有部署配置需要处理的事项：

1. Compose 未传入 `BACKEND_MODE`、`XAI_API_KEY`、`XAI_VOICE`。`.env.local` 被 `.dockerignore` 排除，不能期待容器内 `load_dotenv` 自动读到这些配置；Compose 插值也必须明确选择该环境文件。
2. `AGENT_NAME` 虽已读取，但 `@server.rtc_session()` 没有绑定名称，与 `assistant_manager.py` 的按名 dispatch 不一致。
3. Compose 依赖外部 `livekit-network`，服务器目前不存在此网络；代理仅监听宿主机 loopback，需明确容器访问代理的方案。
4. Compose 当前健康检查仅检查 Python 能否退出，应改为检测 Agent 健康端点。默认 3 副本不宜直接用于本次单机联调。
5. 当前助手只有通用问答/网页搜索，没有订单草稿工具或 HMI 回传链路。订单功能仍需单独实现并验证。

先等待 ReSpeaker 完成枚举，再做实际收放声；服务端后续以现有 xAI 实时配置为联调起点，修正部署与调度、验证代理下实时连接，然后接入 HMI 订单草稿。

## 19:57 ReSpeaker 识别与录音测试通过

- USB 已出现 `2886:0019 Seeed Technology Co., Ltd. ReSpeaker Lite`，设备路径 `usb-3610000.usb-2.3`。ALSA 为 card 2、设备名 `Lite`、device 0。后续应使用稳定设备名，不依赖可能随插拔变化的卡号 2。
- USB 描述符显示当前固件的采集/播放均为 S16_LE、双声道、16000 Hz；这不是 48 kHz 固件。PipeWire 的重采样不改变 USB 硬件支持的采样率。
- PipeWire 输入为 `alsa_input.usb-Seeed_Studio_ReSpeaker_Lite_0000000001-00.analog-stereo`，输出为对应的 `alsa_output` 名称。录音音量 100%，播放 40%，两者均未静音。
- 指定该输入进行 12 秒限时采集，收到 11.9 秒音频。每声道峰值 9227/32768、RMS 404.14（约 -38.18 dBFS），189122/190400 个样本非零，无削波。已有有效数值信号及音量变化，尚未完成语音可懂度或语音识别验证。退出码 124 来自主动作出的限时停止。
- 指定该输出播放两声测试音，退出码 0；现场是否听见仍待用户确认。
- 开发容器中能看到声卡及 `/dev/snd/pcmC2D0c`、`pcmC2D0p`；这里只确认可见性，未运行容器内 ROS 音频节点或验证其用户访问权限。
- 本次没有改变系统默认输入/输出，两者仍指向 APE；后续采集/播放配置必须显式选择 ReSpeaker 或设置系统默认设备。

证据：`artifacts/audio-check-2026-11-18/respeaker-result.json`、`respeaker-capture.wav`。这是第一次实际针对 ReSpeaker 的采集测试，与之前 APE 的全零录音分开保存。

## 服务端配置依据

LiveKit Server 负责房间及实时媒体；Agent Server 作为独立进程通过 WebSocket 注册并接收任务。其基础配置是 `LIVEKIT_URL`、`LIVEKIT_API_KEY`、`LIVEKIT_API_SECRET`，另加所选模型服务的凭据。具体模型和版本尚未选择，本次没有部署 Agent 或修改远端服务。

- [LiveKit 自托管 Agent 部署](https://docs.livekit.io/deploy/custom/deployments/)
- [LiveKit 显式 Agent dispatch](https://docs.livekit.io/agents/server/agent-dispatch/)
- [LiveKit Agents 概览](https://docs.livekit.io/agents/)


## 主板喇叭出声确认与默认设备配置

用户确认喇叭接在 ReSpeaker 主板扬声器插座，3.5 mm 孔未插任何设备。首次轻提示音未听见；随后绕过 PipeWire，使用 `hw:CARD=Lite,DEV=0` 播放 S16_LE、16 kHz、双声道、峰值 -20 dBFS 的四声提示音，用户明确确认听见。播放期间 USB 端点状态为 `Running`，瞬时频率 16000 Hz，退出码 0。说明 USB 播放到主板喇叭的链路已可用。

首次信号峰值仅 8%，再经过 PipeWire 40%（-23.88 dB）衰减，可能过轻；直接播放成功并不能单独证明 PipeWire 故障。已将默认录音和播放切为 ReSpeaker，播放音量改为 80%，通过默认 `paplay` 链路复测，退出码 0。该次默认链路复测的现场听音结果尚未单独确认。输入音量保持 100%，未更改固件或混音器硬件设置。

配置变更前后记录在 `artifacts/audio-check-2026-11-18/respeaker-routing.json`，直接播放证据在 `respeaker-direct-playback.json`。如需恢复本次变更前的默认设备和音量：

```bash
pactl set-default-source alsa_input.platform-sound.analog-stereo
pactl set-default-sink alsa_output.platform-sound.analog-stereo
pactl set-sink-volume alsa_output.usb-Seeed_Studio_ReSpeaker_Lite_0000000001-00.analog-stereo 40%
```

ReSpeaker 固定设备名和 USB 16 kHz 参数可作为后续音频节点配置依据；尚未验证 ROS 节点实际采集/播放、LiveKit 双向音频和订单语音交互。

## Docker 音频访问验证

以现有开发容器的 `admin` 用户调用镜像内 `libportaudio.so.2` 实测：ReSpeaker 输入和输出均能成功 `Pa_OpenStream`，随后关闭；未启动播放或录音。参数为 16000 Hz、双声道，输入 S16、输出 Float32（PortAudio 转换）。当前枚举的 PortAudio index 为 24，不能将它视为重启/插拔后的稳定编号。

容器 `admin` 已属于 audio GID 29，与 `/dev/snd` 设备所属组一致；现有启动器使用 `--privileged` 和 `/dev:/dev`。镜像已有 PortAudio，工作区已安装 `audio_common` 的 `audio_capturer_node`、`audio_player_node`，无需为当前 USB 声卡另装内核驱动或重建镜像。`aplay/arecord/pactl` 命令在当前容器中未找到，这不妨碍 PortAudio 节点使用设备；如需容器内手工 ALSA 排障，可再将 `alsa-utils` 加入镜像。

重要区别：此次容器 PortAudio 的默认输入仍为 APE、默认输出仍为 HDA/HDMI。宿主机 PipeWire 默认设备设置不会自动成为容器的 ALSA/PortAudio 默认设备。后续需按 ReSpeaker 名称解析 PortAudio index 并传给两个 ROS 节点，配置 rate=16000、channels=2，连接 `/audio` 与 `/audio_play`；仅启动 Docker 不会自动启动这些节点。无需为这种直接 ALSA 访问额外共享宿主机 PulseAudio socket。

## AEC 优化完成，准备进入 LiveKit 联调

已在开发容器完成真实 ROS 收放声和软件 AEC 验证。新增独立启动入口
`ros2 launch audio_aec respeaker.launch.py`，自动解析唯一 ReSpeaker 设备，
使用 16 kHz / 20 ms 播放与采集块、40 ms AEC 缓冲。
默认 `/voice_audio/out` 接助手音频，`/voice_audio/clean` 提供净化麦克风。
未接入默认机器人启动，未更改远端 Agent。

本轮安静测试第二遍总能量下降约 13 dB；净化流的 ROS 交付延迟约 62 ms。
用户试听插话后确认“清楚完整，机器人播报残留可接受”。首轮残留仍存在，
下一阶段要验证 LiveKit ASR 是否误认机器人自身播报，以及目标订单句识别结果。
完整参数、比较方法和局限见 `docs/aec-validation-2026-11-18.md`。
