# 独立传输音量：当前证据与未完成项

用户要求调整传输音量而非系统音量，并希望增益超过原有上限。仅移除旧滑块、
控制测试音或把百分比改为 200% 均不算完成这项需求。

## 已确认事实（2026-10-11）

- 当前 Android 使用系统 A2DP 发送其他应用的媒体；AudioShare 没有这些音频样本。
- Windows `AudioPlaybackConnection` 只管理连接，音频由操作系统播放。
  官方接口未暴露 PCM 读取、播放节点或增益设置。
- 在当前 Windows 机器上只读枚举 WASAPI 音频会话：目标手机的 A2DP SNK
  播放会话归属于 `Audiosrv`，并非 AudioShare。未修改会话或终端音量。
- 枚举到的普通录音端点没有提供可直接替代当前播放路径的目标手机 PCM 端点。
  这是当前机器上的观察，不是所有驱动的通用结论。
- 旧 Android `setStreamVolume` 调用及其权限已移除。旧 channel 的写入方法返回
  `independent_volume_unavailable`，不会把传输增益请求转发到系统媒体音量。

## 需要选择的音频通路

此前已向用户询问是否允许新增音频捕获和局域网传输，或必须保持纯蓝牙。
回复前不引入网络音频或新的捕获权限。

1. 若允许捕获和局域网：使用 Android AudioPlaybackCapture、用户授权的
   MediaProjection 会话与前台服务，建立应用自己的音频传输和 Windows 播放流。
   需要处理捕获撤销、后台生命周期、鉴权、抖动缓冲和断线恢复。受保护或禁止捕获的
   播放源不保证可用，不能宣称替代全部系统音频。
2. 若保持纯蓝牙：需进一步验证可访问的 A2DP PCM 接收路径，或由 Android 捕获后
   经独立蓝牙通道传音频。后者仍需要捕获授权，还要验证编码、吞吐和延迟；
   Windows 的普通单会话音量仅有 0–100% 衰减，不能替代超过 100% 的增益处理。

无论采用何种方案，增益应作用于应用拥有的 PCM 流，并包含平滑变更、削波处理、
静音及 100% 原始电平。验收需验证系统音量保持不变、静音有效、超过 100% 能实际
提高低电平信号，以及取消连接后音频停止。必须用双端实际播放验证。

## 参考

- [Microsoft：启用远程蓝牙音频播放](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/enable-remote-audio-playback)
- [AudioPlaybackConnection API](https://learn.microsoft.com/en-us/uwp/api/windows.media.audio.audioplaybackconnection)
- [Android：捕获音视频播放](https://developer.android.com/media/platform/av-capture)
