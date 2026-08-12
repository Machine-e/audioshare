# ADB + scrcpy 长期无线音频方案

## 想法

在不 root、不安装 Magisk 的前提下，先让电脑取得一次 ADB 调试授权，之后尽量通过无线 ADB 启动
scrcpy 的设备端进程，把 Android 播放音频转发到 Windows。USB 只用于首次授权或故障恢复，日常连接走
局域网；如果无线 ADB 能通过虚拟网络访问，也可以进一步验证 Tailscale/EasyTier 场景。

这是一条面向开发者、自用设备或实验模式的路线，不是给普通 APK 永久授予系统音频权限。scrcpy 每次
启动仍依赖可用的 ADB 连接。其默认 `output` 源与 `playback` 源能力不同，不能笼统地按普通 APK 的
`AudioPlaybackCapture` 能力判断。

## 可行性结论

- 可以做到一次授权后，大多数日常连接不再插 USB。
- 不能承诺一次 USB 后永久无人值守。手机重启、无线调试被系统关闭、换网、IP/端口变化、撤销授权或
  厂商省电策略都可能要求用户重新操作。
- Android 11+ 应优先使用系统的“无线调试”配对。配对密钥通常会保留，重连不等于重新配对。
- 传统 `adb tcpip 5555` 更容易自动化和使用固定端口，但手机重启后通常失效，需要 USB 再次开启。
- ADB/scrcpy 不会把 `shell` 能力永久转交给 AudioShare APK；应由 Windows 端通过 ADB 启动设备端进程。
- scrcpy 音频转发要求 Android 11+；Android 11 启动时需要保持屏幕解锁，Android 12+ 通常可直接使用。

## 路线一：Android 11+ 无线调试

手机和电脑处于同一可信网络时，在开发者选项中开启“无线调试”，选择“使用配对码配对设备”。手机会
分别显示配对地址和连接地址，这两个端口不要混用。

首次配对：

```powershell
adb pair <手机IP>:<配对端口>
# 按提示输入手机显示的配对码
```

建立调试连接：

```powershell
adb connect <手机IP>:<连接端口>
adb devices
```

配对关系一般会被手机和电脑保存。后续只要无线调试仍开启，可直接重新连接；设备支持 mDNS 且发现正常
时，ADB 也可能自动发现已配对设备：

```powershell
adb mdns services
adb devices
```

这种方式的主要问题是连接端口可能变化，Windows 上的 mDNS 发现也不一定始终可靠。因此自动化程序应先
检查 `adb devices`，再尝试 mDNS 发现，最后提示用户从手机无线调试页面读取当前连接地址。

## 路线二：一次 USB 授权后启用固定 TCP 端口

首次连接 USB，在手机上确认“允许这台电脑进行 USB 调试”，最好勾选“总是允许”。然后执行：

```powershell
adb devices
adb tcpip 5555
adb connect <手机IP>:5555
adb devices
```

确认列表中的无线地址状态为 `device` 后即可拔掉 USB。日常重连：

```powershell
adb connect <手机IP>:5555
```

这条路线适合固定测试机和固定局域网 IP，但 `adb tcpip 5555` 通常不会跨手机重启持续生效。重启后若
5555 端口没有监听，需要重新插 USB 执行 `adb tcpip 5555`。给手机设置 DHCP 地址保留可以减少 IP 变化，
但不能解决服务被系统关闭的问题。

## 启动纯音频 scrcpy

无线设备已出现在 `adb devices` 后，可以先用 scrcpy 默认的 `output` 源验证。它映射到 Android 的
`REMOTE_SUBMIX`，以转发整体设备输出为目标，并会停止手机本机播放：

```powershell
scrcpy --serial <手机IP>:<连接端口> --no-video --no-control --audio-source=output --require-audio
```

`--require-audio` 可让音频初始化失败直接成为可观察的启动失败，而不是在无声时继续运行。

Android 13+ 可改用 `playback` 源，在电脑播放的同时保留手机本机播放：

```powershell
scrcpy --serial <手机IP>:<连接端口> --no-video --no-control --audio-source=playback --audio-dup --require-audio
```

`playback` 源使用播放捕获，应用可以主动禁止被捕获。默认 `output` 源能力更广，但仍应实机验证 DRM、
通话、受保护内容和厂商限制，不承诺能捕获 Android 上的每一种声音。

具体参数以随包使用的 scrcpy 版本为准。验证时至少覆盖音乐/视频、游戏、禁止捕获的 app、DRM 内容、来电、
切换 Wi-Fi、息屏和手机重启，并分别记录 `output` 与 `playback` 的结果。

## 生命周期与恢复策略

Windows 端可以按以下顺序做自动恢复：

1. 从 `adb devices` 查找已连接设备。
2. 如果目标离线，使用保存的地址执行 `adb connect`。
3. Android 11+ 连接端口失效时，尝试 ADB mDNS 发现已配对设备。
4. 连接成功后启动 scrcpy，并监控进程退出和音频活动。
5. 采用有限次数的退避重试，避免持续高频唤醒手机或刷满日志。
6. 自动恢复失败时，明确区分“无线调试关闭”“地址变化”“设备未授权”和“scrcpy 启动失败”。
7. 只有传统 5555 模式在手机重启后失效，或调试授权已撤销时，才提示重新使用 USB。

建议保存的是设备序列号、最近成功的连接地址、连接方式和 scrcpy 版本，不要保存无线配对码。配对码是临时
凭据，正常情况下只在 `adb pair` 时使用一次。

## 对 AudioShare 的最小集成设想

第一阶段先把它作为 Windows 端的实验性外部模式：

- 检测 `adb` 和 `scrcpy` 是否可用，并显示版本。
- 列出 ADB 设备，让用户选择目标手机。
- 提供连接、启动纯音频、停止和重新连接操作。
- 分开显示 ADB、设备端进程和音频活动状态，避免把“连接成功”误报成“已经收到声音”。
- 保留日志，但过滤配对码和其他临时凭据。

验证稳定后，再评估是继续托管外部 scrcpy 进程，还是复用 scrcpy-server 的音频协议并接入 AudioShare 的
Windows 播放链路。后者维护成本更高，而且会随 scrcpy-server 协议变化，不应作为第一步。

## 权限与能力边界

- scrcpy 的设备端进程由 ADB 以 `shell` 身份启动，不等于 AudioShare Android APK 获得了相同权限。
- 默认 `output` 源使用 `REMOTE_SUBMIX`；Android 13+ 的 `playback`/`--audio-dup` 模式允许目标 app
  主动禁止捕获。两者不能视为同一种权限路径。
- DRM、通话、受保护内容和厂商定制行为仍需实机验证，ADB 可用不代表所有声音都一定能够捕获。
- 关闭开发者选项、关闭无线调试、撤销电脑授权或删除已配对设备后，需要重新授权或配对。
- 部分厂商会在重启、省电、换网或长时间闲置后关闭无线调试，无法只靠 Windows 端保证恢复。

## 安全注意事项

- 只在可信局域网或访问控制明确的虚拟网络中开放 ADB。
- 不要把 TCP 5555 暴露到公网；它提供的不是单一音频权限，而是范围很大的调试能力。
- 不要在日志、配置或 UI 中持久化配对码。
- 为 AudioShare 集成时默认只绑定/连接用户明确选择的设备，不扫描或连接未知设备。
- 提供明显的断开入口，并说明如何在手机的开发者选项中撤销已配对电脑。

## 试验成功标准

- 首次授权或配对完成后，拔掉 USB 仍能启动纯音频 scrcpy。
- 日常断线后无需重新授权即可恢复。
- 能正确识别手机重启、地址变化和授权撤销，并给出对应恢复提示。
- 至少连续运行数小时，覆盖息屏和 Wi-Fi 短暂中断。
- 明确记录各测试 app 是否允许捕获，以及声音是否在手机本机保留。
- 证明该模式失败时不会影响 AudioShare 现有的公开捕获和 Windows 接收模式。

## 参考

- Android Developers，Wireless debugging：<https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi>
- scrcpy audio 文档：<https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md>
- scrcpy connection 文档：<https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md>
