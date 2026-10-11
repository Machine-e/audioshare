# 第一阶段 PRD 与执行方案

确认依据：本次用户明确要求执行第一阶段，并以耳机设备管理 App 截图作为双端简约 UI 参考。
本文件是本阶段的执行范围；已有 Baseline 的音频链路与事实边界继续有效。

## 目标与范围

让普通 Android 手机无需 root、ADB、USB 调试即可沿系统 A2DP 将媒体交给 Windows；
让连接步骤、音量、断连恢复和电脑常驻体验可理解、可操作。

- Android：应用内圆形电脑卡片、扫描与配对、收藏/最近使用、分步骤连接引导、
  手机媒体音量、短测试音及人工听音确认、桌面快捷方式及快捷设置磁贴。
- Windows：记住上次明确选择的设备、准确连接状态、显式启动/停止/重试、托盘常驻与退出选择。
- 双端：浅灰背景、白色大圆角卡片、蓝色强调、清晰设备图标、适度留白；深色与窄屏可用。
- 运行权限：`MODIFY_AUDIO_SETTINGS`、附近设备 `BLUETOOTH_CONNECT` / `BLUETOOTH_SCAN`；
  扫描声明 `neverForLocation`，不申请定位、录音、网络、通知监听或前台服务权限。
- 状态通道：安全蓝牙 RFCOMM，只读同步电脑接收状态，不传音频或遥控指令。
- 不做：电脑音量遥控、网络音频、录音、EQ、蓝牙编码切换、开机自启、自动抢占路由。
- **明确排除电脑睡眠/唤醒测试**；其他硬件项目仍须验收，无法执行则记录阻塞。

## 用户流程与验收

### 手机

1. 授权附近设备并开启蓝牙；点击已配对电脑卡片连接状态服务，或 + 扫描、
   点击新电脑发起系统配对确认。手机系统设置仅作为故障兜底入口。
2. 在电脑端选择手机，启动接收。
3. 在手机系统媒体输出中选择电脑；App 不使用隐藏接口强制切换。
4. 主动播放 2.5 秒低音量媒体测试音，可提前停止，后台释放。
5. 用户选择“在电脑上听到了”或“未听到”。只人工确认声音；电脑接收状态来自独立通道，
   必须目标为本手机且 mode=opened 才提示连接打开，不把配对或另一手机的路由当成功。

音量只控制 `STREAM_MUSIC`；拖动时显示预览，结束后提交并显示系统实际返回值。
固定音量设备不可调整，错误有反馈，返回 App 或按刷新重新读取。
蓝牙绝对音量可能联动，不能把手机媒体音量当作独立电脑音量。
普通 App 不可强制全局 A2DP 路由或静默确认配对；Android 14+ 请求系统输出面板，
Android 12–13 引导使用播放 App 的媒体通知。快捷入口只减少打开和选设备步骤。

### 状态协议与隐私

- 固定服务 UUID：`8fa6bca1-bd4c-4bde-bd1c-c7b45e05a711`；配对、认证与加密，单客户端。
- UTF-8 单行 JSON，最多 512 字节，一秒一次：
  `{"v":1,"mode":"waitingForRoute","target":"thisPhone"}`。
- mode：stopped / starting / waitingForRoute / opened / disconnected / error；
  target：thisPhone / otherPhone / unknown，按真实蓝牙地址比较，不按名称推测。
- 12 秒连接超时，5 秒无完整状态超时；后台断开、前台单次恢复，无无限自动重连。
- 窗口隐藏保留服务；退出关闭；状态服务失败不关闭 A2DP；收藏与最近设备只本地保存。

### 电脑

- 未启动、启动中、等待手机选择、路由已连接、停止中、断开、错误分别显示。
- `opened` 只表示媒体路由打开，不证明正在播放或音质正常。
- 首次明确选设备；缓存缺失设备时保持记忆但不选择别的设备，不自动启动。
- 用户刚选的设备优先于晚到的缓存；快速连续选择按顺序写入本地缓存。
- 枚举失败不改变接收会话；设置入口失败有非致命提示；断开后提供手动重试。
- 关闭窗口询问：保留托盘 / 退出停止接收 / 取消。托盘支持显示和退出。
- 隐藏不销毁窗口、engine、channel 或连接；退出统一清理。
- 图标创建失败不隐藏，Explorer 重启重建图标；重建失败恢复窗口。

## 先知分析后的技术决策

1. 使用原生 `FlutterWindow + Shell_NotifyIconW`，不增加 Flutter 托盘依赖。
   Windows channel 是 Sink 的唯一所有者；显示/隐藏不能调用 start/stop。
2. 修复启动取消时连接所有权已移交、catch 再次 Close 的路径：移交后仅由状态所有者清理，
   未移交的连接与事件订阅才由启动任务兜底释放。
3. 保存设备意图 ID，从最新列表派生有效选择；缓存初始化和枚举并行，用户选择后旧缓存作废。
4. 注册表 `HKCU\Software\AudioShare` 保存 `preferred device`；无云同步，不保存音频。
5. Android 使用公开 AudioManager / ToneGenerator API；测试音走媒体流，不走通话流。

## 执行顺序与所有权

1. 审阅现有状态、生命周期及权限；先知解决托盘生命周期与设备缓存竞争决策。
2. Windows coder：原生托盘、设备缓存 channel、连接清理；Android coder：音量和短测试音。
3. Flutter coder：平台桥接、设备记忆、双端 UI、控件与状态回归；发现交互问题后 debugger 修复。
4. 主 agent：独立 diff 检查、综合测试/分析、两端构建、真实 Flutter 渲染截图检查。
5. 真机验收后才能标记阶段整体完成；不推送、不发布，不以旧版 exe 或模拟截图代替原生验收。

## 自动化与真机验证

```powershell
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat analyze
E:\Programs\flutter\bin\flutter.bat test test\visual_preview_test.dart --dart-define=EXPORT_PREVIEWS=true
E:\Programs\flutter\bin\flutter.bat build apk --release
E:\Programs\flutter\bin\flutter.bat build windows --release
```

渲染测试使用 fake 平台数据和真实 Flutter 控件，截图输出 `build/ui-previews/`；
仅验证界面，不验证蓝牙或原生托盘。Windows 本机字体仅用于截图，不随 App 分发。

真机矩阵（均须记录手机型号/Android、Windows、蓝牙适配器及驱动、日期）：

| 项目 | 方法 / 通过条件 |
| --- | --- |
| 无调试使用 | 安装 APK 后关闭 USB 调试，断开 USB，以普通用户身份完成系统配对和播放 |
| 向导与音量 | 设置返回、硬件音量键后刷新、静音/固定音量；滑块与系统实值一致 |
| 测试音 | 手机/电脑输出分别验证，主动停止、2.5 秒结束、进入后台停止，不遗留音源 |
| 状态 | waiting → opened → 切回手机/断连，不能把“已配对”当“正在播放” |
| 连续播放 | 至少 15 分钟，手机锁屏，反复隐藏/恢复电脑窗口，记录音频是否中断 |
| 恢复 | 手机断开/重连、手动重试、缓存设备移除/重新出现，不擅自改选其他设备 |
| 退出 | starting/waiting/opened/stopping 下关闭选择与托盘退出，无悬挂、重复清理或残留图标 |
| 托盘故障 | 图标创建失败不隐藏、Explorer 重启后可恢复窗口 |
| 睡眠唤醒 | 本次明确不执行 |

## 早期版本验收记录（新增伴侣功能前）

代码已实现，当前可复现验证结果：

- Flutter 全部 31 项测试通过（含 8 个真实控件渲染场景），analyze 无问题。
- 已检查浅色/深色/窄屏、Windows opened/disconnected、Android 固定音量、读取失败、人工确认截图。
  播放前听音确认按钮为禁用态，这是预期语义，不表示检测到无声。
- Android release APK 构建通过：`build/app/outputs/flutter-apk/app-release.apk`。
  aapt 检查最终权限只有 MODIFY_AUDIO_SETTINGS 和 AndroidX 自有签名级 receiver 权限；
  没有麦克风、网络、蓝牙扫描、通知或前台服务权限。
- MinGW 编译运行 `sink_state_machine_test` 通过；以 Windows 10 API 宏运行
  `flutter_window.cpp` / `preferences_channel.cpp` C++17 syntax-only 检查通过。
  这些检查不能替代 MSVC 链接、WinRT channel 集成与真实托盘测试。
- `git diff --check` 通过。

### Windows 工具链补齐与构建（2026-09-06）

- 已安装 Visual Studio Build Tools 2022（VCTools 推荐组件，含 MSVC/CMake/Windows SDK），
  路径 `E:\Programs\VS2022BuildTools`。安装器旧 D 盘缓存/共享组件路径已改为 E 盘；
  变更前注册表备份保留在 `build/vs-setup-before-shared-path.reg`。
- Windows Release 构建及 MSVC `sink_state_machine_test` 编译运行通过。
- 实机启动时发现 Create 前 Destroy 导致销毁标记未复位，已在 OnCreate 修复并重新构建。
- 未开启音频会话时，已验证关闭选择框、取消、隐藏后进程存活、向原生托盘回调发送
  NIN_SELECT 后同一窗口恢复、明确退出返回 0；已检查目标原生窗口截图。
  该回调测试不等同于实际点击系统托盘菜单或测试 Explorer 重启。
- 便携包 `dist/AudioShare-Windows-portable.zip` 包含 Flutter 资源、引擎及 x64 VC++ 运行库，
  不包含状态机测试 EXE。旧构建目录保留为 `build/windows/x64-before-toolchain`。

真实无调试连接、手机锁屏、持续播放、音频会话中的托盘操作及断连重连仍待真机验收。
这些不属于已经通过的检查，不能据此宣布第一阶段硬件验收完成；睡眠唤醒仍按用户要求排除。

### 伴侣功能增量验证（0.2.0+2）

- 45 项 Flutter 测试通过，包含 13 个真实控件渲染场景；analyze 无问题。
  回归覆盖设备选择、不跳设置、过期状态拒绝、另一手机目标、快捷入口、音量拖动、
  320px/两倍文字，以及状态服务失败不能停止 A2DP。
- 已检查手机浅色/深色/窄屏、权限/空设备/扫描、路由打开/断开、音量失败和 Windows 截图。
  图片使用模拟平台数据，不代表真机蓝牙验收。音量未知显示“—”，不伪装成 0%。
- 两端 Release 构建与 MSVC 状态机测试通过；APK 签名校验通过。
  最终 APK 权限为 MODIFY_AUDIO_SETTINGS、BLUETOOTH_CONNECT、BLUETOOTH_SCAN，
  以及 AndroidX 自有签名级 receiver 权限，无录音、网络、前台服务权限。
- 新增状态服务后，在无音频会话下再次验证原生窗口隐藏、托盘回调恢复、退出返回 0。
  未覆盖真实托盘点击、运行中音频、客户端已连接时退出或 Explorer 重启。
- 当前未连接可自动测试的 Android 真机；首次配对、实际输出面板、RFCOMM 双端状态、
  OEM 桌面快捷方式/磁贴及持续播放仍待实机验收。电脑睡眠唤醒明确不测。

### 状态误报修复与动画（0.2.1+3）

- 先知确认代码存在两条不同问题链：RFCOMM 不可用被文案扩大为电脑不可用；
  APC DeviceInterface ID 被当作 BluetoothDevice ID 在后台调用 FromIdAsync，可能使 target 未知。
  尚无该次真机日志，不能认定具体是哪一条触发。
- Windows 改按设备关联属性解析地址，AEP 回退检查 Classic 协议；总超时 3 秒、保留 generation。
  属性失败不影响音频；诊断不含完整地址，不按名称匹配。
- Android 分离本机媒体连接/电脑接收状态，未知不伪装断开，后台及事件失效清除旧本机观测。
  A2DP 连接事件可单次恢复所选电脑状态服务，提供独立重试，避免并发重复 profile 请求。
- 设备高亮、步骤图标、状态卡尺寸、音量拖动反馈使用 220ms 过渡；尊重减少动画设置。
- 52 项 Flutter 测试、analyze 和 MSVC 状态机测试通过；渲染检查包含动画中间帧，
  以及本机已连接/状态服务不可用、双端确认、深色场景。未测真机帧率及蓝牙端到端恢复。

### 播放状态与刷新反馈（0.2.2+4）

- 修复 Windows SDP 缺失 RemoteAddr，与微软 WinsockBluetoothConnection 示例一致；
  服务就绪不等同于手机收到状态，新增等待连接、发送帧数、mode/target 诊断。
- Android 按指定电脑的公开 A2DP 连接/播放接口和广播判断；广播观测有界，
  前台 2 秒采样，后台清理，状态服务最多自动恢复 3 次。
- 主标题区分蓝牙媒体已连接/正在播放，电脑状态独立展示。Windows opened 不冒充正在播放。
- Windows 刷新真实重查、显示完成次数及旋转；手机增加进入、按压、扫描、同步及音量刷新动画。
  不用延迟查询制造加载，减少动画设置下禁用新增动效。
- 全部 57 项 Flutter 测试、analyze、两端 Release 构建通过。刷新回归断言调用次数、
  新返回数据、动画中间帧；手机播放→暂停→断开清除旧状态。
- 实际 Flutter 控件录帧用于动画检查，数据为模拟数据；未完成真机 SDP 连接与持续播放验收。
