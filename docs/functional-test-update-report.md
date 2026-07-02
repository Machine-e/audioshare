# Functional Test Update Report

Date: 2026-07-01

## Summary

This report documents the functional changes made after the initial scaffold. The update replaces simulated connection/capture behavior with a real v1 control session, Android playback capture, Opus/UDP audio transport, Windows UDP authentication, native Opus decode, jitter buffering, and `cpal` playback.

## Files Changed

- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/kotlin/com/machinee/audioshare/MainActivity.kt`
- `android/app/src/main/kotlin/com/machinee/audioshare/AudioCaptureService.kt`
- `lib/platform/audio_capture_bridge.dart`
- `lib/platform/windows_audio_player.dart`
- `lib/protocol/audio_packet.dart`
- `lib/main.dart`
- `crates/audioshare_core/src/audio.rs`
- `crates/audioshare_core/src/ffi.rs`
- `crates/audioshare_core/src/jitter.rs`
- `crates/audioshare_core/src/protocol.rs`
- `crates/audioshare_core/src/receiver.rs`
- `crates/audioshare_core/src/transport.rs`
- `windows/runner/CMakeLists.txt`

## Android Permission and Capture Flow

- Added `RECORD_AUDIO` permission declaration.
- Added runtime permission request handling for `RECORD_AUDIO`.
- Added Android 13+ runtime handling for `POST_NOTIFICATIONS`.
- Replaced the previous simulated capture authorization with a real `MediaProjectionManager.createScreenCaptureIntent()` flow.
- Stored successful MediaProjection authorization data for use by the foreground capture service.
- Added user-visible failure messages when audio capture permission or MediaProjection authorization is denied.

## Android Foreground Service Startup

- Changed Android O+ service startup to use `startForegroundService()`.
- Ensured `AudioCaptureService` calls `startForeground()` before creating `MediaProjection`.
- Added defensive handling for foreground-service startup failures to avoid direct crashes on stricter Android builds such as Android 14+ and vendor ROMs.
- Added cleanup for stored MediaProjection data when the service stops or is destroyed.
- Updated the foreground notification text to indicate active system-audio streaming preparation.

## Android Capture and UDP Streaming

- Added `AudioPlaybackCaptureConfiguration` and `AudioRecord` creation inside the foreground service.
- Added exact 20 ms PCM16 frame reads at the configured sample rate and channel count.
- Added zero-frame, read-error, underrun, Opus-frame, and UDP-send runtime counters.
- Added Android `MediaCodec` Opus encoding and authenticated `ASH1` packet generation.
- Added UDP sending to the paired Windows receiver after `PairAccepted`.
- Added best-effort Android audio-focus request while streaming, with user-facing messaging that third-party local playback suppression is not guaranteed.

## Connection Status and Reachability Testing

- Added connection probe states:
  - `idle`
  - `checking`
  - `listening`
  - `reachable`
  - `failed`
- Added a connection status card to both Android and Windows modes.
- Added visible progress indicators for checking/listening states.
- Added reachable and failed states so the UI no longer implies success before a real network check.
- Added status messages for untested, listening, connected, and unreachable states.

## Windows Listening Probe

- Added a TCP listener on the configured Windows port for both diagnostics and v1 control messages.
- The listener accepts probe requests from Android and responds with `AUDIOSHARE_OK`.
- The listener accepts `Hello`, `Pair`, `StartStream`, and `StopStream` control messages.
- Windows validates the pairing code, allocates a session id, derives the audio auth key, and rejects bad codes.
- Windows status changes to listening after successfully binding the port.
- Windows status changes to reachable/connected after receiving a valid Android probe.
- Port binding errors are surfaced in the UI instead of being silently ignored.

## Windows UDP Receive and Playback

- Added UDP binding on the configured Windows port.
- Added Dart-side authenticated `ASH1` packet decoding and session-id validation.
- Added FFI loading for `audioshare_core.dll`.
- Added native player creation, Opus packet push, jitter buffering, Opus decode, silence insertion for missing packets, and `cpal` output.
- Added native output-device listing with fallback to the default device if the DLL is unavailable.
- Updated CMake to build `audioshare_core.dll` with Cargo and copy it next to `audioshare.exe`.

## Android Connection Probe

- Added Android-side TCP connection testing before starting the stream.
- Added a `测试连接` action in Android mode.
- Android now establishes the v1 `Hello` / `Pair` / `PairAccepted` / `StartStream` control session before starting foreground streaming.
- `测试连接` remains a reachability-only diagnostic and no longer marks audio streaming as successful.
- Added a periodic background probe while Android is capturing/streaming, so loss of reachability stops local capture after repeated missed heartbeats.

## UI and State Updates

- Added a new `connected` link state.
- Added `paired`, `capturing`, `streaming`, and `disconnected` states.
- Reworked start/stop button enablement so active states are handled consistently.
- Added stop support for pairing/connected/streaming states.
- Reset connection probe state when host or port changes.
- Replaced simulated stream statistics with runtime counters from Android capture and Windows receive/playback paths.
- Added visible status rows for TCP control, MediaProjection, AudioRecord, Opus, UDP sent, UDP received, and Windows playback.
- Improved mobile layout scrolling by replacing the previous narrow `ListView` path with a `SingleChildScrollView` and column layout.

## Build Artifacts

The latest copied build outputs are in `dist/`:

- `dist/AudioShare-Android-debug.apk`
- `dist/AudioShare-Android.apk`
- `dist/AudioShare-Windows-portable.zip`

The debug APK is significantly larger than the release APK because it includes Flutter debug engine libraries, Dart JIT artifacts, multiple ABIs, and validation/debug support libraries.

## Validation Reported

- `flutter analyze` passed.
- `flutter test` passed.
- `cargo fmt --manifest-path crates/audioshare_core/Cargo.toml -- --check` passed.
- `cargo test --manifest-path crates/audioshare_core/Cargo.toml` passed.
- `flutter build apk --debug` passed.
- `flutter build windows --debug` passed and produced `build/windows/x64/runner/Debug/audioshare_core.dll`.
- Debug APK path before copying: `build/app/outputs/flutter-apk/app-debug.apk`.
- Debug APK copied to: `dist/AudioShare-Android-debug.apk`.

## Remaining Limitations

- Real-device end-to-end audio has not been proven in this report; validation still needs Android hardware, a capturable source, and a Windows output device.
- Android `MediaCodec` Opus encoder support can vary by device; unsupported devices surface an error instead of silently streaming.
- Android cannot guarantee local speaker mute/pause for arbitrary third-party playback apps; AudioShare requests audio focus as a best-effort hint only.
- Compatibility testing is still needed for capturable apps, opt-out apps, DRM/protected content, Bluetooth/headset routes, and virtual-network interruption.
