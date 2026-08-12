# HyperOS 3 音频广播 / Auracast 路线调研

Date: 2026-07-03
Last checked: 2026-07-04

## 背景

当前实测现象是：Android 连接 Windows 蓝牙后，不到 2 秒就自动断开。这个现象说明现有
`BluetoothSinkMode` 依赖的 Windows classic Bluetooth/A2DP sink 路线，在 Xiaomi HyperOS 3 设备上
可能不稳定，或者手机侧没有把 Windows 维持为可用的媒体输出端。

用户在 HyperOS 3 中发现的“音频广播”功能，应优先按 Bluetooth LE Audio 的 Auracast broadcast audio
理解，而不是按传统 A2DP 点对点媒体输出理解。

## 查到的功能含义

Auracast 是 Bluetooth LE Audio 的广播音频能力：一个发送端可以把音频广播给附近多个兼容接收端。它通常
面向耳机、助听器、音箱、手机等兼容接收设备，而不是传统蓝牙配对后的 A2DP 音箱模式。

Android 侧的官方用户路径通常叫 `Audio sharing` / `Share audio`，支持通过 Auracast 发起广播；Google 的
Android 帮助页提到路径为 `Connected devices` -> `Connection preferences` -> `Audio sharing`，并可使用
`Broadcast sound using Auracast`。Google 2025 年的 Android LE Audio/Auracast 公告也把部分 Xiaomi 机型
列入兼容设备，包括 Xiaomi 14/15 系列、14T/14T Pro、MIX Flip，以及部分 POCO 机型。小米全球 FAQ 也把
`Auracast broadcast audio`列为 LE Audio 的能力之一。

Windows 侧情况不同。Microsoft 文档说明 Windows 11 22H2 后引入了 Bluetooth LE Audio 支持，但 Microsoft
支持页同时明确提醒：不是所有 Windows 11 设备都支持 LE Audio，即使设备宣传支持 Bluetooth LE 也不一定
可用。更重要的是，AudioShare 当前用的 `AudioPlaybackConnection` 是 classic Bluetooth 远端音频播放连接
路线；HyperOS 的“音频广播”如果是 Auracast，则不是这个 API 的同一条链路。

## 对当前 2 秒断开的判断

短线判断：

- 这更像 `BluetoothSinkMode` 与 HyperOS 3 蓝牙栈、Windows A2DP sink 管理方式、驱动或手机策略不兼容。
- 不能把“蓝牙已配对”视为“Windows 能稳定作为媒体接收端”。
- `AudioPlaybackConnection.StartAsync()` / `OpenAsync()` 成功只说明 Windows helper 一度打开连接，不等价于
  Android 会持续把媒体输出路由到 Windows。
- HyperOS 3 的“音频广播”如果能启动，应作为独立路线验证，不应塞进 `BluetoothSinkMode`。

## 建议新增产品路线：AuracastBroadcastMode

建议在现有 `AudioSourceMode` 产品分层中预留第四条非 root 路线：

```text
auracast_broadcast
  Android / HyperOS 3 Audio Broadcast
  Bluetooth LE Audio / Auracast transmitter
  Windows 需要 LE Audio broadcast receiver 能力，或外接 Auracast 接收硬件
```

UI 文案不要写成“连接 Windows 蓝牙音箱”，而应写成：

- `Android 正在广播 LE Audio / Auracast 音频`
- `需要 Auracast 兼容接收端`
- `Windows 直连接收取决于 LE Audio broadcast receiver 支持`
- `如果 Windows 无法发现广播，请使用外接 Auracast 接收器或改用投屏路线`

## 推荐验证顺序

### 1. 先验证 Android 广播是否真的可用

在 HyperOS 3 上测试：

1. 打开蓝牙设置中的“音频广播”或类似入口。
2. 查看是否能设置广播名称、密码、二维码或公开/私密广播。
3. 用一个已知支持 Auracast / LE Audio broadcast 的耳机、助听器、手机或接收器加入广播。
4. 播放当前 `AudioPlaybackCapture` 会读静音的第三方 app，确认接收端能听到声音。

只有第 4 步成功，才说明这条路线能解决“任意第三方 app 声音到外部设备”的核心问题。

### 2. 再验证 Windows 能否作为接收端

Windows 直连接收不应作为第一假设。需要单独验证：

- Windows 版本是否支持 LE Audio。
- 蓝牙适配器和驱动是否支持 LE Audio。
- Windows 设置里是否存在 `Use LE Audio when available` 或等价开关。
- Windows 是否能发现 HyperOS 的 Auracast 广播。
- 是否存在可被桌面 app 调用的稳定 broadcast receiver API。

如果 Windows 只能做 LE Audio unicast 或只支持向耳机“分享音频”，而不能作为通用 Auracast 接收端，那么
AudioShare 不能直接靠当前 Windows runner 接收 HyperOS 音频广播。

### 2026-07-03 本机扫描记录

对 HyperOS 3 `Machine的Xiaomi 14` 的音频广播二维码做了两轮 Windows 侧探测：

- 二维码可解码为 Bluetooth LE Audio / Auracast 风格参数，包含 `UUID=184F`、广播名
  `Machine的Xiaomi 14`、广播地址字段、`BC` 广播密码。
- 不开启扩展广播扫描时，Windows BLE watcher 能看到普通 BLE 广告，但匹配不到该广播。
- 开启 `BluetoothLEAdvertisementWatcher.AllowExtendedAdvertisements = true` 后，Windows 能看到扩展广播：
  - 实际广播地址：`2A:B7:DB:DA:C6:F6`。
  - 广播名：`Machine的Xiaomi 14`。
  - 广播类型：`Extended`。
  - 广播数据包含 `type=0x16` 两段、`type=0x30` 一段、`type=0x09` 本地名称。
  - 75 秒内命中 36 次，RSSI 约 `-30` 到 `-50 dBm`。
- 二维码中的 `AD` 字段与实际扫描到的广播地址不一致，应按广播内容和名称匹配，不能只按二维码地址匹配。
- Windows Runtime 可用于“发现”扩展广播，但当前公开 API 中没有找到可把 `BC` 广播密码提交给系统并加入
  Auracast/BIS 音频流的桌面 API。

这个结果说明：AudioShare 可以做 Auracast 广播发现和诊断服务，但不能仅靠普通 Windows 用户态服务完成
Auracast 音频接收和播放。

### 2026-07-04 最现实路线检查

本机按“先确认系统是否已经能接收，再评估是否值得自研”的顺序检查，结果如下：

- Windows 报告为 `Windows 10 Home China`，内部版本族为 `10.0.26100.x`，64 位。
- 蓝牙控制器是 `Realtek Bluetooth Adapter`，硬件 ID 为 `USB\VID_13D3&PID_3571\00E04C000001`。
- 当前蓝牙驱动为 Realtek `18.4028.2506.2301`，INF 为 `oem62.inf` / `rtkbtfilter.inf`。
- 设备管理器能枚举出 `Machine的Xiaomi 14` 的 classic Bluetooth 项、LE Device 项和多个 GATT 服务。
- 其中能看到类似 `00001849`、`0000184C`、`00001855` 的 LE 服务枚举，说明 Windows 蓝牙栈确实看到了手机的 LE 能力。
- AudioShare 的 scanner helper 仍能通过 WinRT extended advertisement 扫描发现 HyperOS 音频广播，并返回
  `joinApiAvailable=false`。

#### 本机 Auracast 接收能力矩阵

这轮检查的目标是拆开确认本机是否具备 `Auracast join`、`BIG sync`、`BIS 解密`、`LC3 接收/解码`，而不是只确认
“能否扫描到广播”。

| 能力项 | 本机检查结果 | 依据 |
| --- | --- | --- |
| 扫描 BLE extended advertisement | 具备 | `BluetoothLEAdvertisementWatcher` 可用，scanner helper 12 秒内发现疑似 Auracast/LE Audio extended 广播。 |
| 识别 Xiaomi/HyperOS LE 广播线索 | 部分具备 | PnP 可见 `Machine的Xiaomi 14`、`BTHLE` 设备和 `00001849`、`0000184C`、`00001855` 等 LE 服务，scanner 可见 `0x16` 广播数据。 |
| Auracast join / broadcast sink API | 未发现 | WinRT 探针显示 `BluetoothLEBroadcastAudio`、`BluetoothLEAudioBroadcast`、`BluetoothLEBroadcastReceiver`、`BluetoothLEBroadcastSink`、`BluetoothLEBroadcastAssistant` 均不存在。 |
| Periodic Advertising Sync | 未发现 | WinRT 探针显示 `BluetoothLEPeriodicAdvertisementWatcher` 不存在；SDK metadata 搜索 `PeriodicAdvertisement` 无命中。 |
| BIG sync | 未发现 | SDK metadata 搜索 `BIG`、`BroadcastAudio`、`BroadcastSink` 无命中；Windows app 层没有可调用 BIG sync 入口。 |
| BIS payload 接收 | 未发现 | WinRT 探针显示 `BluetoothLEIsochronousChannel` 不存在；SDK metadata 搜索 `Isochronous`、`BIS` 无命中。 |
| broadcast code / BIS 解密 | 未发现 | 没有 join/BIG/BIS 数据路径时，`BC` 只能记录，不能提交给系统完成解密。 |
| LC3 接收/解码 API | 未发现 | WinRT 探针显示 `BluetoothLEAudioCodec`、`BluetoothLEAudioCodecConfiguration` 不存在；SDK metadata 搜索 `LC3` 无命中。 |
| 系统蓝牙栈直接音频输出 | 未确认具备，当前不可用 | 驱动层可见 `BTHUSB`、`BTHPORT`、`BthLEEnum`、`BthA2dp`、`BthHFAud` 等 classic/LE 枚举与传统音频驱动，但未发现 Auracast broadcast receiver 音频端点。 |

结论：这台机器目前只能确认“能发现广播”，不能确认、也没有暴露出“能加入广播并接收音频”的应用层能力。若
Windows 系统内部或驱动私有层有未公开能力，AudioShare 也无法通过当前 WinRT/.NET/Flutter Windows runner
调用它。

### 2026-07-04 新查找：让 Windows 具备 Auracast 接收能力的办法

#### 1. Windows 原生 LE Audio / Shared Audio 路线

Microsoft 现在确实在 Windows 11 上推进 Bluetooth LE Audio 和 Shared Audio。关键点是：

- Windows LE Audio 不是普通应用层蓝牙 API；它依赖 Windows Bluetooth LE Audio Profile、Bluetooth core stack、
  IHV/厂商 ACX streaming driver、LC3 codec、控制器和音频驱动共同组成音频端点。
- Microsoft 文档明确描述了 broadcast source 和 broadcast sink 所需的音频格式、LC3 codec、ACX factory circuit、
  VSAP 等驱动层要求。
- Shared Audio 面向的是“Windows PC 把自己的音频广播给两个 LE Audio 耳机/助听器/音箱”，也就是 PC 作为
  broadcast source。Microsoft 的公开说明要求 PC 和两个音频配件都支持 Bluetooth LE Audio，并通过 Quick
  Settings 的 `Shared audio` 入口启动。
- Microsoft 支持页对 LE Audio 的要求是：Windows 11 22H2+、兼容 Bluetooth LE 支持、兼容音频 codec、以及来自
  厂商的 Bluetooth LE radio 和 audio codec 驱动。如果 `Use LE Audio when available` 不出现，通常就是当前设备
  没有 LE Audio 支持或缺少兼容驱动。
- 这条路线不能直接解决“Windows app 加入 Android/HyperOS 3 的 Auracast 广播并解码播放”。它说明 Windows
  有 LE Audio broadcast 驱动模型，但当前公开体验主要是 PC 发射，不是 app 可控接收外部 Auracast。

对当前机器的判断：

- 当前 Realtek `VID_13D3&PID_3571` 没有暴露 LE Audio broadcast receiver / sink API。
- 即使系统升级，仍需要 OEM/厂商同时提供 Bluetooth radio 和 audio codec 的 LE Audio-capable 驱动；不是随便
  安装一个普通用户态工具就能打开。
- 即使未来系统出现 `Shared audio`，它也首先是 Windows 向耳机/音箱广播的 source 功能，不等于 AudioShare 能
  调用公开 API 加入 Android/HyperOS 的 Auracast broadcast。

#### 2. 可灵活装卸的第三方 Windows 驱动/工具

这轮没有查到“通用、可灵活装卸、能让 Windows 作为 Auracast receiver 的第三方驱动”。

已查到但不适用的方向：

- `Alternative A2DP Driver`：它是替换 Windows A2DP classic audio 驱动、调整 SBC/AAC/aptX/LDAC 等 classic
  Bluetooth codec 参数的工具。其 FAQ 明确写到没有计划处理 LE Audio。因此它不能提供 Auracast join、BIG sync、
  BIS、LC3 receiver。
- `Bluetooth Audio Receiver` / A2DP Sink 工具：这类工具只走 classic Bluetooth A2DP sink。它可以让部分手机把
  普通媒体音频发到 Windows，但和 HyperOS 3 的 Auracast 音频广播不是同一条链路，也解释不了当前 2 秒断开。
- Intel Smart Sound / OEM LE Audio 驱动包：网上有个别用户通过特定 Intel 平台、Intel SST for Bluetooth LE
  Audio、OEM 音频驱动启用 LE Audio 的经验，但它是硬件/OEM/驱动强绑定路线，不是适合当前 Realtek 机器的
  通用可装卸方案，也没有证明能作为 Android Auracast broadcast sink。
- 旧式 BlueSoleil / 第三方 Bluetooth stack：公开能力集中在 classic Bluetooth profile，例如 A2DP/AVRCP，不是
  LE Audio BAP broadcast sink。

如果只考虑“插上即可、拔掉即可”，现实上更接近的是专用 USB Auracast receiver / LE Audio dongle：它自己完成
Auracast join、broadcast code、BIS/LC3，并在 Windows 上枚举成 USB audio 设备。这个属于外接接收器，不是让
AudioShare 直接接管内置蓝牙。

#### 3. Linux / BlueZ / PipeWire / Zephyr 路线

开源栈里存在更接近“真 Auracast receiver”的实现路径，但它不等于 Windows app 能直接用：

- Linux 上 LE Audio 通常由 BlueZ 做 Bluetooth host stack，PipeWire 做音频路由。Collabora 2025 年文章说明
  PipeWire 支持 BAP 的 unicast sink/source 和 broadcast sink/source；控制器需要支持相关能力。
- Linux 侧可用 `bluetoothctl` 的 management menu 检查控制器能力：unicast 看 `cis-central/cis-peripheral`，
  broadcast 看 `iso-broadcaster/sync-receiver`。
- Zephyr 提供 `BAP Broadcast Audio Sink` sample，能扫描 BAP Broadcast Source、同步并接收；但要求 BlueZ host
  或 BLE 5.2 板卡，并需要 ISO feature support。

对 AudioShare 的含义：

- 可以考虑用 Linux live USB/双系统验证某个蓝牙控制器是否支持 `sync-receiver`，这比在 Windows 上猜测更直接。
- WSL 不适合作为这条路线的目标，因为它通常拿不到完整 Bluetooth HCI/ISO 控制权。
- 要把这条路线带回 Windows app，仍然需要专用硬件、libusb/WinUSB 或自写驱动，以及 LC3/WASAPI 输出链路。

### 2026-07-04 新查找：接管 Android / HyperOS 3 音频的其他路线

#### 路线 A：集成 scrcpy 音频转发，作为最现实的软件路线

scrcpy 官方文档说明：Android 11+ 支持 audio forwarding，Android 12+ 基本开箱可用，Android 13+ 可用
`--audio-source=playback --audio-dup` 在转发到电脑的同时保留手机本机播放。它不需要 root，也不需要在手机上
长期安装 app，但需要 USB debugging 或 wireless debugging。

限制：

- 仍受 Android `AudioPlaybackCapture` 策略限制。目标 app 如果禁止被捕获，或音频用途不是允许的 media/game 等，
  仍可能静音。
- 它不是 HyperOS 音频广播路线，而是 ADB/shell server 路线。

对现有项目的改造建议：

1. 新增 `AdbScrcpyAudioMode`。
2. Windows 端检测 `adb` / `scrcpy` 是否可用，或者随包携带 scrcpy helper。
3. 最快可先外部调用 `scrcpy --no-video --no-control --no-window` 或 `scrcpy --audio-source=playback --audio-dup`。
4. 中期再考虑复用 scrcpy-server 协议，把 Opus 音频包接入现有 Rust/Windows 播放器，而不是立即自写 Android
   capture service。

这条路线最可能在“不 root、不外接接收器”的条件下得到声音，但不能保证捕获所有受保护 app。

#### 路线 A2：sndcpy，作为 scrcpy 集成前的轻量验证工具

`sndcpy` 是 scrcpy 作者早期做的 Android audio forwarding PoC：通过 ADB 启动一个 Android 端小服务，再把音频
转发给电脑端 VLC。它不需要 root，支持 Windows/Linux/macOS，但项目文档也明确提示：只能转发没有禁止
`AudioPlaybackCapture` 的 app；scrcpy 2.0 以后已经内置音频转发，因此长期路线应优先看 scrcpy。

对现有项目的用法：

1. 如果要最快验证 HyperOS 3 是否允许某个 app 被捕获，可以先提供 `sndcpy`/`scrcpy` 外部工具 checklist。
2. 如果验证可行，再把 AudioShare 的 `AdbScrcpyAudioMode` 做成一键启动和状态诊断。
3. 不建议把 sndcpy APK 作为长期核心依赖；它更适合作为兼容性探针。

#### 路线 B：Wireless Display / Miracast / 投屏

Windows 可作为 Miracast/Wireless Display 接收端；Microsoft 文档描述 Windows/Android 可通过 Miracast 进行无线
投影，投影链路包含显示和音频。

优点：

- Android/HyperOS 侧是系统级投屏入口，通常比第三方 app 的 `AudioPlaybackCapture` 权限更高。
- AudioShare 已有 Wireless Display 路线，可以继续强化 checklist、状态提示和 Windows 输出活动 meter。

限制：

- 依赖 Xiaomi/HyperOS 是否保留 Miracast 或兼容投屏入口。
- DRM/受保护内容可能黑屏或无声。
- AudioShare 不能直接拿到 PCM，只能引导系统投屏并检测 Windows 是否有输出活动。

#### 路线 C：Phone Link / Link to Windows

Phone Link 可以镜像部分 Android app，但官方说明媒体控制中的音频会继续从 Android 设备或其连接的扬声器播放，
不是稳定的“手机全局音频进 Windows”路线。它不适合作为 AudioShare 的主方案，只能作为用户已有生态的补充提示。
更准确地说，Phone Link 的公开音频能力主要是显示和控制手机当前播放的媒体通知；它不是一个把 HyperOS 全局
PCM 音频送入 Windows 的通用音频 sink。

#### 路线 D：USB 音频 / AOA2

Android Open Accessory 2.0 曾支持 Android 向 USB accessory 输出 2ch/16-bit/44.1kHz PCM，但 AOSP 明确标注
AOAv2 audio support 已在 Android 8.0 deprecated。现代 HyperOS 3 不应把这条路线作为主线。

普通 USB-C 数字音频 DAC/耳机路线是 Android 作为 USB host，把声音输出到外部 USB audio 设备；如果再接入
Windows，需要 USB 采集卡/声卡等外设，因此不符合“纯软件接管”。

#### 路线 E：root / Magisk / AirMusic

AirMusic 官方说明可把 Android 上几乎任意 app 的音频流式传输到 AirPlay、DLNA、SONOS、Google Cast、Fire TV、
软件接收器等；其 Magisk module 用于 root recording / system-mode。

优点：

- 在允许 root 的前提下，最接近“接管所有 Android 音频”的现成方案。
- 可把 Windows 侧作为 DLNA/AirPlay/Google Cast/软件接收器来验证。

限制：

- 需要解锁 bootloader/root/Magisk 或 KernelSU/APatch，Xiaomi 设备通常会涉及数据清除、风控、保修和银行/支付
  app root 检测问题。
- 这会改变项目假设：从“非 root AudioShare”变成“root/system audio route”。

#### 新的路线排序

在“不外接 Auracast 接收器”的约束下，建议优先级调整为：

1. `AdbScrcpyAudioMode`：最高现实价值，最快能在 Windows 上听到一部分 Android/HyperOS 音频。
2. `SndcpyProbeMode`：作为 scrcpy 集成前的轻量验证，不作为长期核心链路。
3. `WirelessDisplayMode`：继续强化，适合作为系统投屏兜底。
4. `AuracastBroadcastMode`：保留扫描诊断，不承诺接收。
5. `BluetoothSinkMode`：保留 classic A2DP sink，但标注 HyperOS 3 兼容性弱。
6. `RootAirMusicMode`：只作为用户明确接受 root 风险后的高级路线。
7. 自研 Windows Auracast receiver：除非准备单独投入 BLE controller、WinUSB/libusb/driver、BAP/BASS/PACS、
   BIS/LC3/WASAPI，否则不进入短期开发。

现实判断：

1. 这不是“缺验证码输入框”的问题。二维码里的 `BC` / broadcast code 只在接收端已经能执行 Auracast join、
   PA sync、BIG sync、BIS 解密和 LC3 音频数据接收时才有用；当前 Windows app 层没有这个 join/audio data path。
2. Windows 蓝牙设置里的两个 `Machine的Xiaomi 14` 不是 Auracast 广播入口。它们是 classic/LE 设备枚举项，
   点击后 2 秒断开只说明普通蓝牙连接链路没有维持媒体路由，不代表 Auracast 广播加入失败。
3. 现有可交付能力应定位为“发现广播 + 诊断 + 防误导文案”，而不是“Windows 直接接收 Auracast 音频”。
4. 如果不能使用外接接收器，短期没有稳定、低风险的 Windows app 内听声路线；继续加验证码输入框或点击设备卡片
   发起连接只会制造误导。

若必须继续走“Windows app 内自研接收”路线，实际需要另起一个底层蓝牙接收栈项目：

1. 准备可被应用独占控制、明确支持 LE Isochronous / BIG Sync 的 BLE 5.2/5.3 控制器。
2. 避开 Windows 标准蓝牙音频栈，使用 WinUSB/libusb、厂商 SDK 或自写驱动访问 HCI/ISO 数据路径。
3. 实现 Auracast 广播解析、Periodic Advertising Sync、BIG Sync、broadcast code 派生、BIS 解密、LC3 解码。
4. 把解码后的 PCM 送入 WASAPI 输出，并维护控制器、驱动、Windows 版本和 Android 机型兼容矩阵。

对这台 Realtek `VID_13D3&PID_3571` 机器来说，最现实的结论是：保留当前 scanner 作为诊断工具，不建议把
内置 Realtek 适配器直接改成 WinUSB/libusb 目标。替换驱动会牺牲系统蓝牙功能，仍不保证控制器和固件暴露
足够的 ISO/BIS 能力。

## Windows 服务可行性判断

可以写的服务：

- 扫描 HyperOS 3 音频广播二维码。
- 开启 BLE extended advertisement 扫描。
- 发现附近的 Auracast/LE Audio 广播，显示名称、RSSI、广播数据和超时状态。
- 记录广播密码、设备型号和 Windows 蓝牙适配器信息。
- 引导用户使用系统能力或外接 Auracast 接收器。
- UI 可以让用户点击已发现广播查看诊断说明。不要把 Windows 蓝牙设备列表里同名的手机 classic/LE 枚举项当作
  Auracast 加入入口；点击这些设备后 2 秒断开，与是否发现 Auracast 广播不是同一条链路。如果系统没有明确暴露
  Auracast receiver/join 能力，AudioShare 仍不能直接取得 BIS/LC3 音频。

普通 Windows 服务目前不适合承诺的能力：

- 直接加入 Auracast broadcast。
- 与控制器建立 Periodic Advertising Sync / BIG Sync。
- 使用 broadcast code 解密 BIS。
- 取得 LC3 帧并解码成 PCM。
- 把 Auracast 音频作为 AudioShare 自己的 Windows 播放流。

原因是这些能力通常需要系统蓝牙栈、驱动和控制器共同暴露 LE Audio broadcast sink 数据路径。当前本机公开
WinRT 能力只验证到扩展广播扫描和 classic `AudioPlaybackConnection`，没有验证到可用的 Auracast receiver
join/audio API。

如果必须让 Windows 直接接收 Auracast，需要走更重的路线：

1. 使用支持 LE Audio ISO/BIG sync 的专用蓝牙控制器。
2. 绕过 Windows 标准蓝牙音频栈，使用 WinUSB/libusb 或厂商 SDK 控制 HCI。
3. 自行实现广播发现、PA sync、BIG sync、BIS 解密、LC3 解码和 WASAPI 输出。
4. 维护硬件兼容矩阵。

这已经不是普通后台服务，而是自研 LE Audio 接收栈和硬件适配项目。

### 3. 最现实的短期落地：外接 Auracast 接收器

如果 Android 音频广播有效，但 Windows 无法直连接收，建议把第一阶段方案改成：

```text
HyperOS 3 音频广播 -> 外接 Auracast 接收器 -> USB/3.5mm/HDMI 音频进入 Windows
```

对 AudioShare 项目而言，这可以被建模为“外部系统路由”：

- AudioShare 负责 checklist、兼容性说明、测试步骤和输出活动 meter。
- 音频链路由 Android + Auracast 接收硬件完成。
- Windows 端继续用 WASAPI meter 判断系统输出是否有声音。
- 如果接收器以 USB audio 设备枚举，AudioShare 可以提示用户在 Windows 声音设置中选择它，或未来增加输入/输出设备检测。

这条路线比在 Windows app 内直接实现 Auracast receiver 更可控。

## 不建议现在投入的方向

不建议短期在 AudioShare 中实现自研 Auracast receiver：

- Auracast 基于 Bluetooth LE Audio broadcast，不是普通 BLE GATT 扫描后就能拿到 PCM。
- LE Audio 使用 LC3、BIS/BIG、Periodic Advertising 等控制器和系统蓝牙栈能力，通常需要 OS/driver 暴露音频端点。
- Windows 桌面 app 层是否能稳定接管 broadcast receiver，目前不应假设。
- 自研接收链路会把项目范围从 Flutter/Rust 音频传输扩大到蓝牙控制器、LE Audio profile、LC3、同步和硬件兼容矩阵。

## 对 AudioShare 的具体改动建议

短期建议：

1. 在 UI 中把 `BluetoothSinkMode` 标注为 `classic Bluetooth / A2DP sink`，并新增“HyperOS 3 可能快速断开”的
   故障说明。
2. 新增 `AuracastBroadcastMode` 文档入口，先不承诺 Windows 可直连，只提供 HyperOS 音频广播验证 checklist。
3. 在 Windows 端保留 WASAPI output meter，作为外部路由是否真的有声音的共同诊断。
4. 在诊断页记录：
   - 手机型号、HyperOS 版本；
   - 是否能启动音频广播；
   - 是否需要密码/二维码；
   - 哪个接收设备成功；
   - Windows 是否能直接发现广播；
   - classic Bluetooth 是否 2 秒断开。
5. 如果用户有外接 Auracast 接收器，把它作为优先验证目标，而不是继续追 Windows A2DP sink。

中期建议：

1. 做一个 `ExternalRouteMode` 子类型：
   - `bluetooth_classic_sink`
   - `auracast_broadcast`
   - `wireless_display`
2. Android 端增加按钮：
   - `打开蓝牙设置`
   - `打开音频广播设置`（如果系统 intent 不稳定，则先展示手动路径）
   - `打开投屏设置`
3. Windows 端增加能力探测：
   - Windows 版本；
   - 蓝牙适配器信息；
   - LE Audio 开关提示；
   - 默认输出活动 meter；
   - classic sink helper 断开原因。
4. 把“连接成功”和“听到声音”分成两个状态，不再用蓝牙连接状态替代音频成功状态。

## 建议结论

HyperOS 3 的“音频广播”值得加入路线图，但它不是修复现有 `AudioPlaybackConnection` 2 秒断开的同一问题。
它更适合作为新的 `AuracastBroadcastMode`：先通过兼容接收端验证 Android 能广播受保护 capture policy 之外的
第三方 app 音频，再决定是否投入 Windows 直连接收。

当前项目最务实的下一步是：

1. 保留 `BluetoothSinkMode`，但降级为兼容性有限的 classic Bluetooth 方案。
2. 将 HyperOS 3 音频广播作为独立实验路线记录。
3. 优先用外接 Auracast 接收器验证端到端声音，而不是立即自研 Windows Auracast receiver。

## 参考来源

- Bluetooth SIG, Auracast broadcast audio announcement:
  <https://www.bluetooth.com/press/bluetooth-auracast/>
- Android Help, use multiple Bluetooth audio accessories / Audio sharing:
  <https://support.google.com/android/answer/16550669>
- Google Android Blog, LE Audio Auracast support expands to more Android devices:
  <https://blog.google/products-and-platforms/platforms/android/le-audio-auracast-support/>
- Xiaomi FAQ, What are the highlights and characteristics of LE Audio:
  <https://www.mi.com/global/support/faq/details/KA-517385/>
- Microsoft Learn, Bluetooth Low Energy Audio in Windows drivers:
  <https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/bluetooth-low-energy-audio>
- Microsoft Support, check if a Windows 11 device supports Bluetooth Low Energy Audio:
  <https://support.microsoft.com/windows/check-if-a-windows-11-device-supports-bluetooth-low-energy-audio-2b79c085-0353-4467-8306-ebb2657a91de>
- Windows Insider Blog, Extending Bluetooth LE Audio on Windows 11 with shared audio:
  <https://blogs.windows.com/windows-insider/2025/10/31/extending-bluetooth-le-audio-on-windows-11-with-shared-audio-preview/>
- Microsoft Community Hub, Share the Moment: Listen Together with Shared Audio:
  <https://techcommunity.microsoft.com/blog/windowsosplatform/share-the-moment-listen-together-with-shared-audio/4522401>
- BluetoothGoodies, Alternative A2DP Driver FAQ:
  <https://www.bluetoothgoodies.com/a2dp/faq/>
- Collabora, Implementing Bluetooth LE Audio and Auracast on Linux systems:
  <https://www.collabora.com/news-and-blog/blog/2025/11/24/implementing-bluetooth-le-audio-and-auracast-on-linux-systems/>
- Zephyr Project, Basic Audio Profile Broadcast Audio Sink sample:
  <https://docs.zephyrproject.org/latest/samples/bluetooth/audio/bap_broadcast_sink/README.html>
- scrcpy audio documentation:
  <https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md>
- sndcpy GitHub repository:
  <https://github.com/rom1v/sndcpy>
- Android Developers, Capture video and audio playback:
  <https://developer.android.com/media/platform/av-capture>
- Microsoft Support, screen mirroring and projecting to your PC or wireless display:
  <https://support.microsoft.com/windows/screen-mirroring-and-projecting-to-your-pc-or-wireless-display-5af9f371-c704-1c7f-8f0d-fa607551d09c>
- Android Open Source Project, Android Open Accessory 2.0:
  <https://source.android.com/docs/core/interaction/accessories/aoa2>
- AirMusic official site:
  <https://www.airmusic.app/portal/>
