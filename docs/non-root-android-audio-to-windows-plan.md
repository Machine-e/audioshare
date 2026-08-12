# 非 root Android 任意音频到 Windows 方案

Date: 2026-07-02

## 目标

在用户不 root、不安装 Magisk、不刷机的前提下，让 Android 上的第三方应用声音尽可能完整地到 Windows 播放。

这条路线不再把 Android 普通 APK 当作音频采集器。它的核心思路是：让 Android 系统自己把媒体音频路由到
Windows，把 Windows 伪装成一个“外部播放设备”。

因此这里的“捕获”不是 `AudioPlaybackCapture` 意义上的 app 内采集，而是系统级外部路由：

- 蓝牙路线：Windows 作为 Bluetooth A2DP sink，Android 把媒体音频发到 Windows。
- 音频广播路线：Android / HyperOS 3 作为 Bluetooth LE Audio / Auracast 发送端，Windows 需要兼容接收端
  或外接 Auracast 接收硬件。
- 系统投屏路线：Windows 作为无线显示接收端，Android 投屏时把音频随投屏流发到 Windows。

## 为什么选择这条路线

普通 Android app 无法通过用户弹窗拿到“任意 app 音频”。`AudioPlaybackCapture` 仍受源 app 的
capture policy 限制。非 root 条件下，最现实的绕过方式不是抓取音频，而是让 Android 系统把音频输出目标
切换为 Windows。

这条路线的优点：

- 不需要 root。
- 不需要绕过第三方 app 的 playback capture policy。
- 用户理解成本接近“连接蓝牙音箱”或“投屏到电脑”。
- 对大多数普通媒体播放 app，更接近“任意声音到 Windows”的体验。

这条路线的限制：

- 不走 Tailscale 的 UDP/Opus 链路。
- AudioShare 普通 Android APK 不拥有源 PCM。
- 受蓝牙、Miracast、Windows 驱动和手机厂商投屏实现影响。
- HyperOS 3 的“音频广播”更可能是 LE Audio / Auracast 广播，不等同于现有 Windows A2DP sink 路线。
- DRM、通话、闹钟、通知、系统受保护音频仍不能承诺 100% 一致。

## 推荐主线：BluetoothSinkMode

### 设计判断

BluetoothSinkMode 应作为非 root 模式的第一主线。Windows 侧目标不是“监听 Android UDP”，而是让
Windows 成为 Android 可以选择的蓝牙音频接收设备。

微软文档说明，Windows app 可以使用 `AudioPlaybackConnection` 让蓝牙连接的远端设备在本机播放音频。
文档场景明确包括让 PC 像蓝牙音箱一样工作，并让用户听到手机音频。底层 A2DP sink 的启用由 app 管理，
不是系统自动常驻开启。

### 用户流程

1. 用户在 Windows AudioShare 中选择 `蓝牙音频接收`。
2. AudioShare 检查 Windows 蓝牙是否可用。
3. AudioShare 引导用户在 Android 设置中配对当前 Windows PC。
4. Windows 端列出已配对且支持远端音频播放连接的设备。
5. 用户选择手机，AudioShare 调用 Windows 音频播放连接能力。
6. 用户在 Android 的媒体输出选择器中选择 Windows PC。
7. Android 上播放任意媒体音频，声音从 Windows 扬声器或用户选择的 Windows 输出设备播放。

### Windows 端实现方向

优先实现一个 Windows-only helper，而不是把逻辑塞进 Android 端：

- 使用 WinRT `Windows.Media.Audio.AudioPlaybackConnection`。
- 使用 `AudioPlaybackConnection.GetDeviceSelector()` 找到支持远端音频播放连接的已配对设备。
- 对选中设备调用 `TryCreateFromId()`。
- 调用 `StartAsync()` 启用连接。
- 调用 `OpenAsync()` 开始播放。
- 监听连接状态变化，显示 `未配对`、`可连接`、`已启用`、`播放中`、`断开`。
- 断开时释放连接资源。

AudioShare 在这个模式下主要做连接管理、状态展示、故障诊断和用户引导。音频数据由 Windows 蓝牙栈接收并
播放到系统音频端点，AudioShare 通常不会直接拿到蓝牙解码后的 PCM。

### 可选增强

- 加一个 WASAPI loopback meter，只用于确认 Windows 当前是否真的有音频输出。
- 加一个“播放测试音”按钮，引导用户在 Android 上播放系统媒体音量测试或任意音乐 app。
- 加一个输出设备提示：如果用户想从耳机/音箱播放，应先在 Windows 里选择默认输出设备。
- 记录每台手机的配对状态和最近连接失败原因。

不要在第一阶段实现自定义蓝牙协议栈或自解码 A2DP。那会明显扩大范围，也未必比 Windows 原生栈稳定。

### HyperOS 3 断连观察

如果 Android 连接 Windows 蓝牙后 2 秒内自动断开，应把它记录为 `BluetoothSinkMode` 的兼容性失败，而不是
网络、UDP 或 Opus 问题。HyperOS 3 上出现的“音频广播”入口应另按 LE Audio / Auracast 路线验证；详见
`docs/hyperos3-audio-broadcast-route.md`。

## 实验路线：AuracastBroadcastMode

### 设计判断

HyperOS 3 的“音频广播”应视作 Bluetooth LE Audio / Auracast broadcast audio。它的模型是 Android 手机作为
广播发送端，附近兼容接收端加入广播；它不是 Windows `AudioPlaybackConnection` 的 classic Bluetooth A2DP
sink 模式。

### 用户流程

1. 用户在 Android / HyperOS 3 中打开“音频广播”。
2. 用户确认广播名称、密码、二维码或公开/私密状态。
3. 兼容 Auracast / LE Audio broadcast 的接收端加入广播。
4. 如果 Windows 不能直连发现广播，则使用外接 Auracast 接收器，并让 Windows 播放或采集该接收器输出。
5. AudioShare 只显示 checklist、兼容性说明和 Windows 输出活动 meter，不把它标记为 UDP streaming。

### 适用场景

- HyperOS 3 classic Bluetooth 连接 Windows 快速断开。
- 用户设备存在“音频广播”入口。
- 用户可以准备 Auracast 兼容耳机、助听器、手机、音箱或外接接收器。

### 限制

- Windows 直连接收 Auracast 不能作为第一阶段默认假设；它依赖 Windows 版本、蓝牙适配器、驱动和系统是否暴露
  broadcast receiver 能力。
- 这条路线不走 Tailscale/UDP，AudioShare 普通 Android APK 仍不拥有源 PCM。
- 自研 Windows Auracast receiver 会显著扩大范围，涉及 LE Audio broadcast、LC3、BIS/BIG、Periodic
  Advertising 和驱动能力，不建议短期投入。

## 备选路线：WirelessDisplayMode

### 设计判断

WirelessDisplayMode 让 Windows 安装并打开系统的 `Wireless Display` 可选功能，Android 通过投屏把画面和
声音一起发到 Windows。它更像“无线 HDMI”，适合蓝牙不可用或用户愿意接受投屏窗口的场景。

微软文档给出的 Windows 11 路径是：

- 安装 `Wireless Display` 可选功能。
- 在 `Projecting to this PC` 中配置可被发现。
- 启动 `Wireless Display` app。
- 从发送设备的投屏/无线显示入口选择这台 PC。

Android 端入口因厂商不同，常见名称包括：

- 投屏
- 无线显示
- 屏幕镜像
- Smart View
- Cast

### 用户流程

1. 用户在 Windows AudioShare 中选择 `系统投屏接收`。
2. AudioShare 检查 Windows 是否安装了 `Wireless Display` 可选功能。
3. 如未安装，打开 Windows 设置中的可选功能页面或展示操作步骤。
4. AudioShare 引导用户打开 `Wireless Display` app。
5. 用户在 Android 上打开投屏/无线显示。
6. 用户选择当前 Windows PC。
7. Android 的画面和音频进入 Windows。

### 适用场景

- 手机不支持稳定的蓝牙 A2DP sink 连接。
- 用户接受投屏窗口。
- 需要较完整的系统媒体路由，但不要求 AudioShare 自己拿到 PCM。
- 目标是“听到手机声音在 Windows 上播放”，而不是低延迟音频专线。

### 限制

- 很多 Android 设备，尤其偏原生 Google 路线的设备，不一定保留 Miracast/WFD。
- 部分投屏路线优先走 Chromecast/Google Cast，不一定能投到 Windows Wireless Display。
- 延迟通常高于蓝牙或专用音频链路。
- 常常会带视频，不是纯音频。
- 多数情况下仍不走 Tailscale。

## AudioShare 产品分层

建议把非 root 路线做成新的 `ExternalRouteMode`，不要和现有 UDP 音频协议混在一起。

```text
AudioSourceMode
  public_capture
    Android MediaProjection + AudioPlaybackCapture
    只支持允许 capture 的 app

  bluetooth_sink
    Windows AudioPlaybackConnection / A2DP sink
    非 root，目标是让 Android 系统媒体音频到 Windows

  wireless_display
    Windows Wireless Display / Miracast receiver
    非 root，画面和音频一起到 Windows

  auracast_broadcast
    Android / HyperOS 3 Audio Broadcast
    Bluetooth LE Audio / Auracast transmitter
    Windows 需要 LE Audio broadcast receiver 或外接 Auracast 接收硬件

  privileged_system_agent
    root/Magisk/system app
    未来用于任意声音 + Tailscale + AudioShare UDP
```

在 UI 文案上，`bluetooth_sink` 和 `wireless_display` 不应写成“Android 端采集成功”，而应写成：

- `手机音频已路由到 Windows`
- `Windows 正在作为蓝牙音频接收端`
- `Windows 正在作为无线显示接收端`
- `Android 正在广播 LE Audio / Auracast 音频`
- `需要 Auracast 兼容接收端`

## 第一阶段 MVP

### Windows

1. 增加 `ExternalRouteMode` 页面。
2. 增加蓝牙模式说明和配对 checklist。
3. 增加 `AudioPlaybackConnection` helper 原型。
4. 枚举可连接手机。
5. 支持启用、打开、释放蓝牙音频播放连接。
6. 显示连接状态。
7. 增加 Windows 输出活动 meter，用 WASAPI loopback 判断是否有声音。
8. 记录 HyperOS 3 classic Bluetooth 快速断开时的 helper 状态和恢复建议。

### Android

1. 不做新权限。
2. 不再尝试通过 `AudioPlaybackCapture` 解决所有 app。
3. 在 app 内提供引导页：
   - 蓝牙模式：打开系统蓝牙设置和媒体输出选择器。
   - 投屏模式：打开系统投屏设置，或展示厂商入口说明。
4. 对普通 capture 模式持续静音的 app，提示切换到蓝牙或投屏模式。
5. 对 HyperOS 3 设备，增加“音频广播 / Auracast”实验路线说明，不把它混入 classic Bluetooth sink。

### 文档和诊断

1. 写清楚蓝牙模式不走 Tailscale。
2. 写清楚 AudioShare 不直接拥有 Android PCM。
3. 写清楚“任意音频”的非 root 含义是系统路由，不是突破 capture policy。
4. 记录各设备测试结果：手机型号、Android 版本、Windows 版本、蓝牙芯片、是否成功。
5. 记录音频广播测试结果：广播是否能启动、是否需要密码/二维码、接收设备型号、Windows 能否直连发现广播。

## 完成标准

BluetoothSinkMode 的退出点：

- Windows 能发现已配对 Android 手机。
- Windows 能启用并打开远端音频播放连接。
- Android 媒体输出中能选择 Windows PC。
- 在至少一个当前 `AudioPlaybackCapture` 读静音的第三方 app 中播放音频，Windows 能听到声音。
- AudioShare UI 能显示连接状态和 Windows 输出活动。
- 断开蓝牙后 UI 能进入断开状态，且有可理解的恢复步骤。

AuracastBroadcastMode 的退出点：

- HyperOS 3 能启动音频广播。
- 至少一个兼容 Auracast / LE Audio broadcast 的接收端能加入广播。
- 当前 `AudioPlaybackCapture` 读静音的第三方 app 播放音频时，接收端能听到声音。
- 如果 Windows 无法直连接收，文档和 UI 能明确说明需要外接 Auracast 接收器。
- AudioShare 不把该模式标记为 UDP streaming。

当前本机验证补充：

- 开启 Windows BLE extended advertisement 扫描后，可以发现 HyperOS 3 音频广播广告。
- 这证明 Windows 可以做发现/诊断服务。
- 当前没有验证到公开 Windows API 可直接加入 Auracast 广播、使用 broadcast code 接收 BIS/LC3 音频并播放。
- 因此第一阶段只能把 Windows 端实现定位为 `Auracast scanner / diagnostics`，不能承诺 `Auracast audio sink`。

WirelessDisplayMode 的退出点：

- Windows 能安装并打开 `Wireless Display`。
- Android 能发现 Windows PC。
- 投屏成功后，Android 第三方 app 音频能在 Windows 播放。
- AudioShare 能给出明确引导和故障排查入口。

整个非 root 目标的退出点：

- 至少提供一条无需 root 的可重复流程，让用户把 Android 第三方 app 声音路由到 Windows。
- UI 不再把公开捕获模式静音误判为网络或编码问题。
- 文档明确区分：
  - 公开捕获；
  - 蓝牙系统路由；
  - 无线显示系统路由；
  - 未来 root/system Tailscale 路由。

## 风险

- Windows 桌面端蓝牙 A2DP sink 能力依赖 app 管理和系统版本，不能假设用户配对后自动播放。
- 某些蓝牙适配器或驱动可能只支持 Windows 作为音频 source，不稳定支持 sink。
- HyperOS 3 classic Bluetooth 连接 Windows 快速断开时，音频广播可能是另一条协议路线，不应当作同一问题修复。
- Windows LE Audio 支持不等于 Windows 可作为通用 Auracast broadcast receiver。
- Android 厂商媒体输出 UI 差异很大，自动化程度有限。
- 投屏能力在不同 Android 设备上差异更大，尤其是 Miracast/WFD 支持。
- 这条路线满足“声音到 Windows”，但不满足“AudioShare 通过 Tailscale 传输任意 PCM”。

## 不做事项

- 不尝试用普通 Android APK 绕过第三方 app 的 capture policy。
- 不把蓝牙/投屏模式标记为 UDP streaming。
- 不在第一阶段实现自定义 A2DP 协议栈。
- 不承诺捕获通话、DRM、系统受保护音频。

## 参考来源

- Microsoft Learn: Enable audio playback from remote Bluetooth-connected devices:
  <https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/enable-remote-audio-playback>
- Microsoft Support: Screen mirroring and projecting to your PC or wireless display:
  <https://support.microsoft.com/en-us/windows/hardware/display-graphics/screen-mirroring-and-projecting-to-your-pc-or-wireless-display>
- Microsoft Support: Fix connections to wireless displays or docks in Windows:
  <https://support.microsoft.com/en-us/windows/hardware/display-graphics/fix-connections-to-wireless-displays-or-docks-in-windows>
- Android Developers: Capture video and audio playback:
  <https://developer.android.com/media/platform/av-capture>
