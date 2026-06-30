# AudioShare

AudioShare streams Android system playback audio to Windows over a virtual
network. It is designed for devices connected through Tailscale, EasyTier, or
another user-managed mesh/VPN, so both sides only need to reach each other by
IP and port.

## First Release Scope

- Android 12+ captures allowed system playback audio.
- Android runs capture/streaming through a foreground service model.
- Windows listens for a paired Android sender.
- Audio uses Opus over UDP with a TCP control channel.
- Windows plays received audio to a selected output device.
- Pairing uses a one-time code, then authenticated audio packets.
- Release artifacts are a Windows portable zip and Android APK.

## Repository Shape

- `lib/` - Flutter UI and app state.
- `crates/audioshare_core/` - Rust protocol, codec, transport, and audio primitives.
- `android/app/src/main/kotlin/com/machinee/audioshare/` - Android platform glue for foreground capture service startup.
- `docs/protocol.md` - v1 protocol notes.
- `scripts/` - local release packaging helpers.

## Development

Flutter is installed locally at `E:\Programs\flutter` in the current workspace:

```powershell
E:\Programs\flutter\bin\flutter.bat pub get
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat analyze
```

Rust is required before native-core checks can run:

```powershell
cargo test --manifest-path crates/audioshare_core/Cargo.toml
```

The Android build uses Gradle 8.14.3, Android Gradle Plugin 8.11.1, and Kotlin
2.2.20. Maven repositories include `storage.flutter-io.cn` and Aliyun mirrors
first for this workspace.

## Release Builds

```powershell
.\scripts\build_windows_portable.ps1
.\scripts\build_android_apk.ps1
```

## Network Setup

1. Install and connect Tailscale or EasyTier on both devices.
2. Confirm Windows and Android can reach each other over the virtual network.
3. Start Windows receiver and note the virtual-network IP, port, and pairing code.
4. Start Android sender, grant system playback capture, and enter the Windows details.

Audio capture depends on Android's playback-capture rules. Apps that block
capture, DRM media, calls, and protected content are outside the v1 support
target.
