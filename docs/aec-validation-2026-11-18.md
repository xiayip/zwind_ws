# ReSpeaker Lite AEC 实测（2026-11-18）

> 本文保留早期调试过程，部署状态以末尾基线记录和
> [夜间静场复测](aec-quiet-2026-11-18.md) 为准。当前 LiveKit 已部署，
> HMI 保留已验收的轮流讲话模式；未验证稳定全双工。

## 结论

**当前可作为 LiveKit 联调基线，尚未完成生产验收。** 已完成实时 ROS 播放参考 → 软件 AEC → 净化麦克风测试，用户确认插话句清楚完整、播报残留可接受。低延迟配置已保存；首轮播放残留和 ASR 误触发仍需在线验证。下文前几节保留本次调试早期记录，最新结果见“实时优化结果”。

目前未启用生产 ROS 音频/AEC 节点，未修改板载固件、未部署 LiveKit Agent。

## 测试条件

- Jetson 宿主机 USB 声卡 ReSpeaker Lite，USB 描述符 bcdDevice=2.07，S16_LE、16 kHz、双声道。
- 容器 `admin` 用户使用 PortAudio/sounddevice，按设备名解析 ReSpeaker，同时播放并录音。直接打开硬件设备，本次数字测试信号不经过宿主机 PipeWire 的 80% 音量设置。
- 喇叭接在主板扬声器插座，3.5 mm 未插线（此前用户确认）。
- 参考为离线生成的中文配送问答语音，峰值为满刻度 15%，每遍 15.8 秒。4 秒静音 + 第一遍 + 1 秒间隔 + 第二遍 + 4 秒静音，总长 40.6 秒。语音由 eSpeak 合成，中文词典不完整，适合作为可重复测试激励，不代表最终助手音质。
- 保存的是经过板载处理后的 USB 麦克风输出，没有取得处理前原始麦克风，也没有切换板载 AEC 开关。因此不能计算板载 AEC 的严格 ERLE，不能仅用输入输出电平差声称板载消除量。
- 三次实时采集均未报告 PortAudio overflow/underflow，样本未达到数字削波阈值；这不排除模拟喇叭或放大电路失真。

设备的板载算法和 USB 固件能力依据：[官方仓库](https://github.com/respeaker/ReSpeaker_Lite)。该文档公开的配置服务为 I2C/I2S 路径，本次未取得可用 USB AEC 开关。

## 实际记录

第一轮期间有人讲话/触碰设备，用户已确认。该轮以 `confounded-*` 保留，不用于纯回声判断。

第二轮用户确认全程安静，麦克风测量如下（均为 RMS dBFS，越接近 0 越响）：

| 区段 | USB 麦克风 |
| --- | ---: |
| 播放前背景，1–3 秒 | -41.60 |
| 第一遍，4–19.8 秒 | -15.11 |
| 第二遍，20.8–36.6 秒 | -17.18 |
| 播放后尾段，37.6–39.6 秒 | -16.03 |

录音与发送参考的最大归一化波形相关系数约 0.163，对应约 470 ms 的峰值偏移。它表明存在播放相关成分，但不是消除量或完整延迟测量。尾段仍较响且原因尚未解释，不能把所有录音能量都算作回声；需要继续检查播放延迟、设备处理和声学环境。

第三轮按用户可配合的答复进行插话采集：播放前说“送到 A 座三楼三零五”，第一遍保持安静，第二遍重复该句。已保存录音，但尚未独立验证实际说话时段、可懂度或识别准确率，不作“插话通过”的结论。

## 软件 AEC 离线对照

直接编译项目现有 `audio_aec::WebrtcAec` 核心，使用容器现有 WebRTC AudioProcessing 0.3.1。每 10 ms 输入播放参考和 USB 麦克风数据，关闭额外高通、降噪和 AGC，以减少混淆。对照组使用相同算法、相同麦克风录音和全零参考。

| 安静测试第二遍语音段 | 输出 RMS dBFS | 相对输入的总电平下降 |
| --- | ---: | ---: |
| 未加软件 AEC | -17.18 | — |
| 正确参考，0 ms 延迟提示 | -26.69 | 9.50 dB |
| 正确参考，470 ms 延迟提示 | -26.92 | 9.74 dB |
| 全零参考对照 | -17.17 | 约 0 dB |

第一遍正确参考仅下降约 1.5–2.0 dB，启动收敛仍需关注。470 ms 是本次录音相关性给出的诊断提示，不是建议直接写死的生产参数。

插话测试第二遍录音总电平下降约 3.87 dB，播放前预期人声时段几乎不变。这些数值不能单独证明近端人声被完整保留，也不能将混合语音的总电平下降当成回声消除量。

离线对照只验证算法核心；没有覆盖 ROS 时间戳、播放队列、调度抖动和真实参考链路。下一步应将 `audio_player_node` 的 `played` 输出作为实际播放参考，输入软件 AEC，检查 `/audio_clean`，并验证纯播放不误触发、近端人声与插话仍可懂。是否叠加软件 AEC，需由这些对照决定。

## 证据与复测

目录：`artifacts/aec-check-2026-11-18/`。

- `probe.py`：按名称选择设备的全双工采集脚本。
- `far-end-{reference,mic}.wav`、`far-end-result.json`：用户确认安静的第二轮。
- `double-talk-{reference,mic}.wav`、`double-talk-result.json`：插话测试。
- `offline_aec.cpp`、`analyze_offline.py`：现有软件 AEC 核心的离线对照入口。
- `*-software-aec.json`：软件 AEC 指标；`*-reference_delay_470ms.wav` 为对应输出。
- `double-talk-usb-excerpt.wav`、`double-talk-software-aec-excerpt.wav`：同一插话时段的处理前后片段，未单独归一化响度。

上述文件保存在本机工作区，没有上传录音到外部模型服务。LiveKit Agent 开发仍是后续目标，语音链路验收应与 Agent 业务逻辑分别记录。


## 实时优化结果

在独立 ROS_DOMAIN_ID=93 中启动音频节点，不启动机器人控制节点。使用实际
`audio_player_node/played` 参考，采集 mic / played / clean 的样本、采样时间戳、
接收时间戳，按实际播放时间选取对应区段。保持同一测试语音与数字幅度。
用户表示可保持安静；不同轮次现场环境和板载处理状态仍会变化，不能把两轮差异
全部归因于参数。没有直接测量硬件 ADC/DAC 端到端延迟。

| 实测项 | 原播放配置 | 20 ms 播放块 |
| --- | ---: | ---: |
| 播放块，16 kHz | 4096 帧 / 256 ms | 320 帧 / 20 ms |
| 播放参考提前到达中位数 | 271 ms | 34 ms |
| 第一遍总能量下降 | 1.83 dB | 2.93 dB |
| 第二遍总能量下降 | 7.18 dB | 13.28 dB |
| 第二遍 USB 麦克风 RMS | -13.84 dBFS | -14.77 dBFS |
| 第二遍净化 RMS | -21.02 dBFS | -28.05 dBFS |

上述“下降”是处理前后的总能量差，**不是板载 AEC ERLE**。软件降噪、AGC、
高通均关闭。原播放器使用设备 high latency，新配置请求 20 ms。
播放器新增 `playback_chunk`、`output_latency_ms` 参数，保留原默认值；专用
ReSpeaker 启动配置选择新值，不改变其他现有调用。

随后把 `mic_buffer_ms` 从 100 改为 40，进行实时插话测试：

- clean 的采样时间戳到接收时间中位数从约 122 ms 降到 61.97 ms，P95 为 63.35 ms。
  这是 ROS 交付延迟指标；采集节点仍使用主机估计时间戳。
- 录音与参考消息均为 320 帧；这一轮未出现采集溢出或 AEC 错误日志。
  播放器当前不输出 PortAudio 回调状态，不能据此声称所有播放欠载均已排除。
- 第二遍混合插话段总能量下降 3.30 dB，不作为独立回声消除量。
- 用户试听 `ros-double-talk-interruption-clean.wav` 后明确反馈：
  **“清楚完整，机器人播报残留可接受”**。
- 保留此参数，不为了追求更小的输出数值而开启额外降噪。

还按原始 ROS 消息到达顺序重放，比较参考 lead 0/50/100 ms、延迟提示
0/100/300/470 ms、降噪开/关，麦克风缓冲 40 ms。小块安静录音的
470 ms 提示在第一遍有改善，但在插话录音上没有一致优势，不写死到启动配置。
降噪改善背景能量，但未经人声主观复核，因此仍关闭。
参数扫描脚本曾因重复加载数组造成内存耗尽被终止，已修正为共享每路数组，
重新完成扫描；这不是实时 AEC 节点故障。

## 可复用配置和验证

在开发容器中加载 workspace 后：

```shell
ros2 launch audio_aec respeaker.launch.py
```

- 每次启动按名称查找唯一的 ReSpeaker 双向设备，缺失/歧义时报错，不回退到板载声卡。
- 输入助手音频：`/voice_audio/out`。
- 输出给 LiveKit 的净化麦克风：`/voice_audio/clean`，16 kHz、单声道、int16、20 ms。
- 中间诊断：`/voice_audio/mic`、`/voice_audio/played`。
- 任一音频节点退出时关闭整个音频启动组；没有加入机器人默认启动或开机服务。
- 尚未将该 topic 接入 teleop_rtc_cpp，也未部署 LiveKit Agent。

源码：`src/zephyr_common/audio_common/audio_aec/launch/respeaker.launch.py`。
新增证据均在原 artifacts 目录：`realtime_probe.py`、`analyze_realtime.py`、
`ros-{baseline,small-block,double-talk}*.{npz,wav,json,log}`、`replay_ros.cpp`、
`sweep_ros.py`、`profile_smoke.py`。记录的音频没有上传外部模型。

验证结果：两个音频包构建成功；21 个 gtest 用例通过；播放器改动的格式检查
修正后通过。安装后的 launch 实机运行 8 秒静音流，三路消息格式/采样率/块长
符合配置，clean 接收延迟均值 61.68 ms。不存在的设备名在启动任何音频节点前
被拒绝；正常停止后三个节点均干净退出，测试结束没有残留采集进程。

## Git 基线

音频代码独立仓库：`src/zephyr_common/audio_common`。
基线提交：`13f0a5780a73c2da0e068ab3db40aaf5027b1c14`（`feat(audio): add validated ReSpeaker Lite AEC baseline`）。
工作区通过独立仓库管理源码，此处记录精确代码版本；测试录音和构建产物保留在本机
被忽略的 `artifacts/` 目录，不纳入 Git。


## LiveKit voice baseline frozen after HMI integration

2026-11-18: HMI/voice runtime baseline `63996fe`; native audio/device selection
baseline `2e0cbfa`. Both repositories carry tag `voice-baseline-20261118`.
The current kiosk uses 80% PCM output volume and turn-taking upload suppression
with a 650 ms tail; complete speech, once-only confirmation, entry/correction
have human acceptance. Building aliases and sound-driven aura have automated
and synthetic-model validation; latest human acceptance is still pending.

Server archive: `/opt/zephyr-voice-agent-baseline-20261118.tar.gz`, SHA256
`717fd1551ed1787d284ce5a1873ac5170666a14fd4ccf73b45dfdc471f69c608`.
Secrets remain in the protected environment file, excluded from Git and archive.
Quiet unattended AEC experiments are authorized after this baseline. Experiments
must disable only diagnostic upload gating and must not replace the accepted
kiosk mode without evidence for both echo rejection and near-end speech.
