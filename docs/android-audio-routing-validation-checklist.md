# Android Audio Routing Validation Checklist

Date: 2026-07-01

Use this checklist as the explicit exit gate for
`docs/android-audio-routing-fix-plan.md`. Automated build/test success is
required, but it is not sufficient by itself: the plan is complete only after
the hardware functional checks below are observed on Android and Windows.

## Automated Validation

Run from the repository root:

```powershell
.\scripts\validate_android_audio_routing.ps1
```

Expected results:

- Rust formatting passes.
- Rust unit tests pass, including packet auth and jitter behavior.
- Flutter analyzer passes.
- Flutter tests pass, including packet auth failure and output-device fallback.
- Android debug APK builds.
- Windows debug app builds.
- `build\windows\x64\runner\Debug\audioshare_core.dll` exists next to
  `audioshare.exe`.

Current status on 2026-07-01: this automated gate has passed in the local
workspace. The goal must remain open until the hardware gates below are
observed and recorded.

## Hardware Setup

Run the local prerequisite helper before device testing:

```powershell
.\scripts\check_android_audio_routing_prereqs.ps1
```

- Windows receiver and Android sender are on the same Tailscale, EasyTier, or
  other user-managed virtual network.
- Windows firewall allows the configured TCP/UDP port.
- Windows mode is started first and displays the current pairing code.
- Android has granted `RECORD_AUDIO`, notifications if required, and the
  MediaProjection consent prompt.
- Android uses a known capturable media source for the happy-path test.

## Happy-Path Exit Gate

The implementation is considered functionally proven when all of these are
observed in one run:

- Android reaches `paired` after the v1 `Hello` / `Pair` / `PairAccepted` /
  `StartStream` control session.
- Android runtime status shows MediaProjection authorized.
- Android runtime status shows AudioRecord capturing.
- Android `PCM 帧` increases above zero.
- Android `Opus 帧` increases above zero.
- Android `UDP 发包` increases above zero.
- Windows `UDP 收包` increases above zero.
- Windows `Windows 播放活跃` is enabled.
- Windows `playedFrames` / playback frame count increases.
- Audio is actually heard from the selected Windows output device.
- If multiple Windows output devices are present, selecting a non-default device
  routes playback there; selecting the default entry falls back to the default
  `cpal` output device.
- `测试连接` remains labeled as reachability only and is not treated as stream
  success.

## Unsupported Capture Exit Gate

Run one app/source that is known or expected to disallow Android playback
capture. The result is acceptable only if:

- The app does not show a false streaming success state.
- Android shows zero-frame or capture-empty diagnostics.
- The UI message is actionable enough to distinguish unsupported capture from
  ordinary network failure.

## Disconnect Exit Gate

During an active happy-path stream, interrupt the receiver or virtual network:

- Stop the Windows receiver, block the port, or disable the virtual-network
  connection.
- Android shows missed heartbeat warnings.
- Android stops AudioRecord capture and UDP sending after the hard timeout.
- Android state changes to disconnected.
- The foreground service and notification clear after stop or timeout.

## Compatibility Policy Gate

The app must not claim guaranteed local phone-speaker mute for arbitrary
third-party playback. The acceptable v1 behavior is:

- AudioShare requests Android audio focus as a best-effort hint.
- AudioShare states that third-party apps may keep playing locally if they
  ignore focus, disallow capture, use protected content, or route audio through
  unsupported device paths.
- Guaranteed pause/mute is reserved for future controlled playback sources that
  AudioShare owns.

## Evidence To Capture

Use the helper below to create a timestamped local evidence folder and
hardware-validation report template:

```powershell
.\scripts\collect_android_audio_routing_evidence.ps1 `
  -WindowsIp "<windows-virtual-network-ip>" `
  -CapturableSource "<capturable-source-app>" `
  -UnsupportedSource "<unsupported-or-protected-source-app>"
```

For a completion report, record:

- Windows virtual-network IP and port.
- Android device model and Android version.
- Capturable source app used for happy-path test.
- Unsupported/protected source app used for negative test.
- Screenshots or logs showing non-zero PCM, Opus, UDP sent, UDP received, and
  playback counters.
- Result of the disconnect test and approximate timeout duration.
