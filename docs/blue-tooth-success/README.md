# AudioShare Bluetooth A2DP Sink 成功记录

日期：2026-08-12

## 结论

Xiaomi 14 可以通过 classic Bluetooth A2DP 将媒体音频稳定播放到这台 Windows 电脑。

本次问题不是手机、Realtek 蓝牙硬件、Windows 配对或虚拟音频设备缺失，而是 AudioShare 的 Windows helper 使用了 Windows PowerShell 5.1 不兼容的 WinRT 异步调用方式。修复后，`AudioPlaybackConnection` 能持续保持 `Opened`，手机端选择电脑作为媒体输出并播放音频成功。

这条成功链路是：

```text
Xiaomi 14 媒体输出
  -> classic Bluetooth A2DP
  -> Windows AudioPlaybackConnection / A2DP Sink
  -> Windows 当前默认音频输出设备
```

它不使用 Tailscale、UDP、Opus、`AudioPlaybackCapture` 或 Auracast。

## 验证环境

- Windows 11 家庭中文版，Build 26200，64 位。
- 电脑：ASUS TUF Gaming A15 `FA507UV`。
- BIOS：`FA507UV.312`。
- 蓝牙：Realtek Bluetooth Adapter。
- 蓝牙硬件 ID：`USB\VID_13D3&PID_3571\00E04C000001`。
- Realtek 驱动：`18.4028.2506.2301`，INF `oem62.inf`。
- 手机：`Machine的Xiaomi 14`，HyperOS 3。
- 排查时当前 Windows 用户已经具有管理员权限。

## 排查结果

### Windows 和蓝牙硬件正常

- `bthserv`、`BTAGService`、`DeviceAssociationService` 和用户级 Bluetooth 服务均在运行。
- Realtek Bluetooth Adapter 状态为 `OK`，Problem Code 为 `0`。
- 近 14 天 System 日志中没有蓝牙相关错误或警告。
- Windows Update 没有提供新的 Realtek 蓝牙驱动。
- ASUS 官方和 Windows Update 提供 BIOS 313，但由于蓝牙问题已通过软件修复解决，没有执行高风险 BIOS 更新。

### 手机 Profile 枚举正常

Windows 能看到 Xiaomi 14 的 classic 和 LE 两套设备记录，并能枚举：

- `Machine的Xiaomi 14 A2DP SNK`，服务 UUID `0000110A`；
- AVRCP Transport；
- Hands-Free HF；
- classic Bluetooth 设备；
- Bluetooth LE 设备和多个 GATT 服务。

`AudioPlaybackConnection.GetDeviceSelector()` 能找到一个启用的设备接口，名称为 `Machine的Xiaomi 14`；`TryCreateFromId()` 也能成功创建连接对象。因此配对、A2DP Source Profile 和 Windows A2DP Sink 接口本身都存在。

## 根因

AudioShare 原先在 `windows/runner/external_route_channel.cpp` 生成的 PowerShell 脚本中使用：

```powershell
$operation.GetAwaiter().GetResult()
```

具体包括：

- `DeviceInformation.FindAllAsync(...).GetAwaiter().GetResult()`；
- `AudioPlaybackConnection.StartAsync().GetAwaiter().GetResult()`；
- `AudioPlaybackConnection.OpenAsync().GetAwaiter().GetResult()`。

在这台机器的 Windows PowerShell 5.1 中，WinRT 异步对象表现为 `System.__ComObject`，没有可直接调用的 `GetAwaiter()`，实际错误为：

```text
方法调用失败，因为 [System.__ComObject] 不包含名为“GetAwaiter”的方法。
```

这会让 AudioShare 在枚举手机或打开 A2DP Sink 时失败。之前观察到的快速断开不能据此归因于 HyperOS 或 Realtek 驱动。

## 代码修改

修改文件：`windows/runner/external_route_channel.cpp`。

### 1. 修复已配对设备枚举

加载 `System.Runtime.WindowsRuntime`，通过 `WindowsRuntimeSystemExtensions.AsTask<T>()` 将 `IAsyncOperation<DeviceInformationCollection>` 转成 Task，再等待结果。

由于 PowerShell 5.1 无法直接推断该泛型扩展方法，helper 通过反射选取 `AsTask` 泛型重载并传入 `DeviceInformationCollection` 类型。

### 2. 修复 A2DP Sink 启动

对 `AudioPlaybackConnection` 使用 PowerShell 的 WinRT 同步投影方法：

```powershell
$startResult = $connection.Start()
$openResult = $connection.Open()
```

同时增加以下检查：

- `Start()` 明确返回布尔 `false` 时报告失败；
- `Open()` 抛出异常时报告具体错误；
- `Open()` 没有返回 `OpenResult` 时报告失败；
- 只有 `$openResult.Status -eq 'Success'` 才进入启用状态。

`Start()` 的合法返回值可能为空，因此不能把空值直接当成失败。

### 3. 保持连接对象存活

helper 成功打开连接后继续常驻：

```powershell
while ($true) { Start-Sleep -Seconds 3600 }
```

这很重要：`AudioPlaybackConnection` 对象被释放或 helper 退出后，Windows 会释放 A2DP Sink。停止 AudioShare 时再主动结束 helper。

## 系统侧低成本调整

关闭了 Realtek 蓝牙适配器的自动省电关闭能力：

```text
MSPower_DeviceEnable.Enable = false
```

对应设备为：

```text
USB\VID_13D3&PID_3571\00e04c000001_0
```

这不是本次代码错误的根因，但可以减少长时间播放时因 USB 选择性挂起产生的断连风险。

排查期间临时启用了以下日志，采集完成后已经恢复为关闭：

- `Microsoft-Windows-Bluetooth-Bthmini/Operational`；
- `Microsoft-Windows-Bluetooth-Policy/Operational`。

## 成功证据

使用修正后的调用方式进行连接测试：

- `TryCreateFromId()`：成功；
- `Start()`：成功；
- `Open()`：返回 `Status=Success`；
- 连接状态从 `Closed` 进入 `Opened`；
- 状态连续保持 `Opened` 超过两分钟，没有出现之前描述的两秒断开；
- Windows Bluetooth Policy 日志记录 classic 和 LE 地址均成功建立连接；
- 用户在 Xiaomi 14 上选择当前电脑作为媒体输出并播放音频，Windows 实际听到声音。

日志中的成功记录包括：

```text
A connection to a remote device 0x3C3824548447 was successfully established.
A connection to a remote device 0x7AF04AFE5A60 was successfully established.
```

其中 `3C:38:24:54:84:47` 是本次 classic Bluetooth/A2DP 设备记录，`7A:F0:4A:FE:5A:60` 是 LE 设备记录。A2DP 成功路线是 classic Bluetooth，不要把 LE 设备项或 Auracast 广播当作同一个连接入口。

## 构建和自动验证

以下检查通过：

```powershell
E:\Programs\flutter\bin\flutter.bat analyze
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat build windows --debug
E:\Programs\flutter\bin\flutter.bat build windows --release
```

结果：

- Flutter Analyze：无问题；
- Flutter Test：10 个测试全部通过；
- Windows Debug 和 Release 均构建成功；
- `git diff --check -- windows/runner/external_route_channel.cpp` 通过。

本次生成的可运行包：

```text
dist\AudioShare-Windows-portable-a2dp-fix-20260812.zip
```

## 可重复的使用步骤

1. 在 Windows 和 Xiaomi 14 上完成普通蓝牙配对。
2. 启动包含本次修复的 AudioShare Windows 版本。
3. 切换到 Windows 接收端的“蓝牙路由”。
4. 刷新并选择 `Machine的Xiaomi 14`。
5. 启动蓝牙音频接收，确认 AudioShare 显示连接已启用。
6. 在 Xiaomi 14 的媒体输出选择器中选择当前 Windows PC。
7. 在手机上播放音乐，声音应从 Windows 当前默认输出设备播放。
8. 播放期间保持 AudioShare 运行；停止时由 AudioShare 释放连接。

## 如果以后再次失败

按以下顺序排查，避免先更换驱动或安装虚拟声卡：

1. 确认运行的是包含本次修复的新包，而不是旧 `dist` 目录中的历史版本。
2. 确认手机仍能枚举出 `A2DP SNK`、AVRCP 和 classic Bluetooth 设备记录。
3. 确认 `AudioPlaybackConnection.GetDeviceSelector()` 能找到手机。
4. 检查 helper 输出中是否再次出现 `System.__ComObject` / `GetAwaiter` 错误。
5. 区分“Windows helper 已打开”和“Android 已选择 Windows 作为媒体输出”；只有前者不代表手机已经开始向电脑发送音频。
6. 临时启用 Bluetooth Policy/Bthmini 日志，复现一次后检查连接事件。
7. 最后才考虑删除两端配对并重新配对、更新 ASUS 官方蓝牙驱动或测试另一只 USB 蓝牙适配器。

本次成功不需要安装 VB-CABLE 等虚拟声卡，也不需要更换 Realtek 驱动、升级 BIOS 或使用外接蓝牙接收器。
