# AudioShare Bluetooth A2DP Sink 成功与排障

最后验证：2026-08-12

## 唯一支持链路

AudioShare 只支持以下 classic Bluetooth 路线：

```text
Android / HyperOS 媒体输出
  -> classic Bluetooth A2DP
  -> Windows AudioPlaybackConnection（A2DP Sink）
  -> Windows 当前默认音频输出设备
```

Android 端只负责打开系统蓝牙设置。配对和媒体输出切换均由系统完成，
AudioShare 不采集手机 PCM，也不传输或解码音频。

## 已验证环境与结论

- 手机：Xiaomi 14，HyperOS 3。
- 电脑：ASUS TUF Gaming A15 FA507UV，Windows 11。
- 蓝牙：Realtek Bluetooth Adapter，驱动 `18.4028.2506.2301`。

Xiaomi 14 已能将媒体音频稳定播放到 Windows。最初定位出的关键问题是
PowerShell 5.1 将 WinRT 对象暴露为 `System.__ComObject`，不能直接调用
`GetAwaiter()`。当前应用已不再启动 PowerShell helper，而是通过 C++/WinRT
直接枚举设备并调用 `StartAsync`、`OpenAsync`，同时在整个接收会话中保持
`AudioPlaybackConnection` 对象存活。蓝牙异步操作在后台执行，不阻塞窗口。

当前 Bluetooth-only Windows 构建已再次从应用内验证：能枚举
`Machine的Xiaomi 14`、连接返回 `Opened`，并且启动与状态轮询期间窗口保持响应。

## 使用步骤

1. 在 Windows 和手机的系统蓝牙设置中完成普通蓝牙配对。
2. 启动 AudioShare Windows 端并刷新已配对设备。
3. 选择目标手机并启动蓝牙音频接收，确认连接已启用。
4. 在 Android/HyperOS 的媒体输出选择器中选择当前 Windows PC。
5. 播放音乐；声音应从 Windows 当前默认输出设备发出。
6. 播放期间保持 AudioShare 运行，结束时在 AudioShare 中停止接收。

## 成功判断

- Windows 能枚举目标手机并创建 `AudioPlaybackConnection`。
- `Start` 和 `Open` 成功，连接持续保持 `Opened`。
- 手机媒体输出已明确选中 Windows PC。
- Windows 实际听到连续音频，而不只是显示“已配对”。

## 排障顺序

1. 确认运行的是最新构建，而不是 `dist` 中的历史包。
2. 在两端系统设置确认配对仍存在；必要时停止接收后重新配对。
3. 确认手机使用 classic Bluetooth 媒体配置，而不是仅有 LE 设备记录。
4. 确认 AudioShare 能枚举手机；当前版本不应启动 PowerShell，也不应再出现
   `System.__ComObject` / `GetAwaiter` 错误。
5. 区分“Windows Sink 已打开”和“手机已选择 Windows 作为媒体输出”；
   前者不会自动完成后者。
6. 确认 Windows 默认输出设备可用、音量未静音，并保持 AudioShare 运行。
7. 若连接容易掉线，检查 Windows 蓝牙服务和适配器状态，并在设备电源管理
   中关闭“允许计算机关闭此设备以节约电源”。
8. 最后再考虑更新电脑厂商提供的蓝牙驱动或测试另一只蓝牙适配器。

## 已知限制

- 蓝牙适配器、驱动、Windows 构建和手机固件会影响兼容性。
- 蓝牙延迟、编解码质量和媒体类别路由由系统决定。
- 通话、闹钟、受保护媒体和非媒体音频可能不走 A2DP。
- 无需虚拟声卡；安装虚拟声卡不能修复 A2DP Sink 连接问题。
