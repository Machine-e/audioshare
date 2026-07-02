# 任意 Android 音频到 Windows 的路线评估

Date: 2026-07-02

## 结论

当前 AudioShare 的 Android 端走的是公开 API：
`MediaProjection` + `AudioPlaybackCaptureConfiguration` + `AudioRecord`。这条路只能采集
Android 策略允许被采集的播放流，不能满足“Android 上任何声音都传到 Windows 上”的最终目标。

用户截图里的状态更像是 Android 端读到了静音帧，而不是 Windows 播放或 UDP 传输单独出错。也就是说：
TCP、授权、`AudioRecord`、Opus/UDP 链路可以继续保留，但“源头 PCM 是静音”这个问题不能靠调 UDP、
Opus 或 Windows 播放修好。

如果目标是“任意声音”，项目需要从“公开捕获模式”升级为“系统路由模式”。公开捕获模式可以保留为兼容模式，
但不应再被当成最终方案。

## Android 公开捕获的边界

Android 官方文档对 `AudioPlaybackCapture` 有明确限制：

- 被采集 app 必须允许 playback capture。
- app 可以通过 manifest 或运行时 capture policy 禁止被第三方采集。
- Android 只允许特定 usage 的播放流进入捕获混音，通话、通知、闹钟、受保护内容等不应假设可采集。
- 普通第三方 app 不能创建一个全局“虚拟扬声器”并强制系统把所有 app 的声音导入它。

因此，当前版本在第三方 app 上只读到静音，是符合 Android 安全模型的结果。继续修当前
`AudioPlaybackCapture` 管线，最多能提升“允许采集的 app”的成功率，无法突破“任何声音”。

## 本地 Xiaomi PC Manager 音频链路观察

本机安装目录：

```text
C:\Program Files\MI\XiaomiPCManager\4.3.0.1881
```

和音频相关的组件包括：

```text
MiDistributedAudio.dll
MiPCAudio.exe
MiPlayPCAudioDll.dll
MiPlayCastSDK.dll
MiPlayCastService.exe
libmirror.dll
LibAudioRecorder.dll
idmruntime.dll
Drivers\Audio\VirtualAudio.inf
Drivers\Audio\VirtualAudio.sys
```

关键判断：

- `Drivers\Audio\VirtualAudio.inf` 注册了 Windows 侧 `Virtual Audio` 驱动，同时暴露 render 和 capture
  接口。这是 PC 侧虚拟音频设备，不等价于 Android 侧的虚拟扬声器。
- `MiDistributedAudio.dll` 里能看到 `distAudio.openSpeaker`、
  `distAudio.startSpeakerStream`、`distAudio.openMicrophone`、
  `distAudio.startMicrophoneStream` 等分布式音频 RPC 名称。
- 同一个 DLL 还出现 `com.miui.audiomonitor`、`com.xiaomi.distaudio`、
  `DistAudioService` 等 Android/MIUI 侧服务名。这说明手机端大概率有 MIUI/OEM 级系统服务参与，
  不是普通 Android app 单独完成。
- `MiPCAudio.exe`、`libmirror.dll`、`MiPlayCastSDK.dll` 暴露了 MiPlay/WFD 风格的接收链路，
  包括 `audio/raw`、`audio/mp4a-latm`、`audio/aac-eld`、PCM payload、AAC/LPCM 相关处理、
  `PCMDevices::pcmWrite` 和 WASAPI 播放路径。
- `LibAudioRecorder.dll` 是 PC 侧 WASAPI capture/render 库，适合处理电脑本机音频输入输出，
  不能直接解决 Android 端任意声音采集。

工程含义：小米方案的关键不在 Windows 端能播放 PCM，而在手机端拥有 MIUI/系统层的音频路由能力。
AudioShare 当前作为普通 Android app 无法复制这个权限层级。

## MiPCManager_Patch 的音频部分

已查看 `https://github.com/Higanoneko/MiPCManager_Patch`，本地 clone 版本：

```text
dcadc841ff0d5d29c950bfbdeb8f7f46d5f18386
```

这个项目的“音频流转增强”不是实现 Android 音频采集，也不是实现通用音频传输协议。它做的是：

- patch `MiPCAudio.exe` 和 `idmruntime.dll`；
- 把三处网卡类型判断统一改成 WiFi 或 Ethernet；
- WiFi 类型字节是 `0x47`，Ethernet 类型字节是 `0x06`；
- 目的是让小米电脑管家的 Lyra/netbus 与 IDM 两套发现/广播机制使用同一张网卡身份，避免有线 LAN
  模式下出现重复设备或发现异常。

所以 `MiPCManager_Patch` 可以帮助小米原有音频流转在有线网络下被发现，但它不提供一个可移植到
AudioShare 的 Android 任意音频采集方案。

## 对具体设想的回答

### 在手机上加一个虚拟扬声器

普通 Android app 做不到。要做“手机上的虚拟扬声器”，需要进入 Android audio policy、AudioFlinger、
HAL 或 OEM 分布式音频服务这一层。可行前提通常是：

- 系统签名 app；
- 预装 privileged app；
- root/Magisk 模块；
- 自定义 ROM；
- OEM 厂商开放的私有 SDK。

如果没有这些权限，AudioShare 无法强制所有第三方 app 把声音输出到自己的虚拟设备。

### 是否需要蓝牙

蓝牙不是必须，但它解决的是另一层问题。

如果让 Windows 充当 Bluetooth A2DP sink，Android 会把系统媒体音频按蓝牙设备路由出去。这可以绕开
`AudioPlaybackCapture` 的 app opt-out 限制，体验上接近“把手机声音放到电脑上”。缺点是：

- 走蓝牙，不走 Tailscale；
- 延迟、码率、稳定性受蓝牙栈和设备影响；
- Windows 需要 A2DP sink 支持、驱动或接收应用；
- 通话、受保护音频、不同音量流的行为仍可能因机型不同而变化。

### 只用 Tailscale 是否可行

可行，但前提是 Android 端已经能在系统层拿到真实 PCM。Tailscale 只能负责 IP 网络通道，不能突破
Android 对音频采集的权限限制。

因此：

- 普通 app + Tailscale：只能传允许 capture 的 app 音频。
- 系统/root/OEM 音频 agent + Tailscale：可以把系统层 PCM 编码成 Opus，复用 AudioShare 现有 UDP
  协议传给 Windows。

## 可选路线

| 路线 | 是否接近“任意声音” | 是否走 Tailscale | 主要依赖 | 对 AudioShare 的意义 |
|---|---:|---:|---|---|
| 当前公开捕获模式 | 否 | 是 | `AudioPlaybackCapture` | 保留为兼容模式，只承诺支持允许 capture 的 app |
| Xiaomi/MIUI 外部集成 | 是，限支持机型 | 通常不是 | 小米电脑管家、MIUI 分布式音频服务、MiPlay | 可做检测/启动/说明，不应复制或分发私有 DLL |
| Bluetooth A2DP sink | 接近，按系统蓝牙路由 | 否 | 蓝牙、Windows sink 支持 | 适合非 root 用户，是最快能听到多数手机音频的方案 |
| Root/Magisk/system agent | 最接近 | 是 | root、priv-app、AudioPolicy/AudioFlinger 级实现 | 最符合 AudioShare 独立产品目标，但工程风险最高 |
| Miracast/WFD 接收 | 接近，通常连视频一起 | 不一定 | 系统投屏、WFD receiver | 可作为外部路由模式，难以做纯音频和跨网络 |
| USB/硬件采集 | 是，取决于设备 | 不一定 | 采集卡、USB Audio、线材 | 稳定但不软件化，产品形态不同 |

## 建议的项目方向

### 1. 把当前管线命名为 PublicCaptureMode

当前代码不是废掉，而是定位要改：

- 保留 `MediaProjection`、`AudioRecord`、Opus、ASH1/UDP、Windows receiver。
- UI 明确显示“公开捕获模式：只支持允许 capture 的 app”。
- 当静音帧持续增长时，不再提示用户排查 UDP，而是提示“源 app 或系统策略不允许捕获”。

### 2. 增加 ExternalSinkMode 概念

ExternalSinkMode 不一定由 AudioShare 自己传 PCM，而是帮助用户使用系统级路由：

- Bluetooth sink：检测/指导 Windows 蓝牙音频接收，适合最快验证“手机所有媒体音频到电脑”。
- Xiaomi/MiPlay：检测本机小米电脑管家组件是否存在，说明它依赖 MIUI/OEM 服务；可以辅助启动，
  但不要把私有组件打进 AudioShare。
- Miracast/WFD：作为外部投屏音频路线记录，不作为当前主线。

这条路线适合非 root 用户，但不会形成“AudioShare over Tailscale”的完整独立链路。

### 3. 如果坚持 Tailscale + 任意声音，立项 PrivilegedSystemRouteMode

这是最符合用户目标的长期主线：

1. Android 端做 root/Magisk/privileged agent。
2. agent 在系统层拿到输出混音 PCM，或创建系统认可的虚拟输出/remote submix。
3. 复用当前 AudioShare 的 Opus 编码、ASH1 鉴权 UDP、Windows jitter/decode/playback。
4. Windows 端基本不用重写，只需要完善 buffer、设备选择、状态诊断。

这个方向的最小可行证明不是“app 能启动”，而是：

- 选择一个已知会让当前 `AudioPlaybackCapture` 静音的第三方 app；
- 在 root/system agent 模式下拿到非零 PCM；
- Windows 端能连续播放；
- 断开 Tailscale 或关闭 receiver 后，Android agent 停止路由或恢复本地输出。

### 4. 不建议把小米 DLL 逆向成项目主依赖

理由：

- 小米链路依赖 MIUI 手机端私有服务，单独复用 Windows DLL 不能让普通 Android 手机产生任意音频流。
- 组件和协议会随 Xiaomi PC Manager 版本变动。
- 分发私有 DLL/驱动有版权、签名和维护风险。
- `MiPCManager_Patch` 证明的是“补丁可改善小米原有发现路径”，不是“协议可独立复刻”。

更现实的做法是把 Xiaomi 当成 ExternalSinkMode 的一个可选外部后端：检测、提示、启动、记录限制。

## 推荐下一步

短期建议：

1. 在 UI 和 docs 中停止把 PublicCaptureMode 描述成“任意 Android 音频”。
2. 给当前静音帧状态加明确错误：`源 app 不允许 Android playback capture，当前模式无法捕获`。
3. 做 Bluetooth sink 的手动验证文档，用来满足非 root 场景下“先听到手机大多数声音”的需求。

中期建议：

1. 设计 `AudioSourceMode`：`public_capture`、`external_bluetooth`、`external_xiaomi`、
   `privileged_system_agent`。
2. Windows receiver 继续作为 AudioShare 的核心资产，保持 UDP/Opus 路线稳定。
3. Android 普通 app 只承担公开捕获和控制 UI，不再承诺系统级路由。

长期建议：

1. 如果产品目标必须是“任何声音 + Tailscale”，启动 root/Magisk/system-agent 原型。
2. 第一阶段只证明 PCM 获取，不先做漂亮 UI。
3. 第二阶段再把 privileged agent 接入现有 ASH1/Opus/UDP 协议。

## 完成标准

这个目标的退出点应定义为可验证的音频事实，而不是连接状态：

- 对一个当前公开捕获模式会静音的第三方 app，Windows 端能播放非零音频。
- Android 端指标能区分“读到真实 PCM”和“读到静音帧”。
- Windows 端指标能显示 UDP received、decoded frames、played frames 都持续增长。
- 断开网络后 Android 端停止发送，并且不会继续误报 streaming。
- 文档/UI 清楚标注当前模式的权限前提：公开捕获、蓝牙外部路由、Xiaomi 外部路由、root/system 路由。

只有达到这些标准，才可以说“任意 Android 音频到 Windows”的 goal 真正完成。

## 参考来源

- Android Developers: Capture video and audio playback: <https://developer.android.com/media/platform/av-capture>
- Android Developers: `AudioPlaybackCaptureConfiguration`: <https://developer.android.com/reference/android/media/AudioPlaybackCaptureConfiguration>
- MiPCManager_Patch: <https://github.com/Higanoneko/MiPCManager_Patch>
- 本机 Xiaomi PC Manager: `C:\Program Files\MI\XiaomiPCManager\4.3.0.1881`
