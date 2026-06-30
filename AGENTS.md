# Project

AudioShare is a Flutter + Rust project for streaming Android system playback
audio to Windows over a user-managed virtual network such as Tailscale or
EasyTier. Android is the sender; Windows is the receiver.

# Dev Commands

Use the local Flutter SDK if it is not on PATH:

```powershell
E:\Programs\flutter\bin\flutter.bat pub get
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat analyze
E:\Programs\flutter\bin\flutter.bat build windows --release
E:\Programs\flutter\bin\flutter.bat build apk --release
```

Rust is expected for the native core:

```powershell
cargo test --manifest-path crates/audioshare_core/Cargo.toml
```

# Architecture

- `lib/` contains the Flutter UI and app state.
- `crates/audioshare_core/` contains protocol, Opus codec, UDP transport, and
  Windows output-device primitives.
- `android/app/src/main/kotlin/com/machinee/audioshare/` contains Android
  platform glue for foreground capture service startup.
- `docs/protocol.md` documents the v1 control and audio packet shape.
- `scripts/` contains release packaging helpers.

# Validation Expectations

Run Flutter tests after UI/state changes. Run Rust tests after protocol, codec,
transport, or audio changes. The Android wrapper is pinned to Gradle 8.14.3,
Android Gradle Plugin 8.11.1, and Kotlin 2.2.20 to match the locally proven
Flutter/Android setup. Android repositories include `storage.flutter-io.cn`
first so Flutter engine artifacts resolve in this workspace. For release work,
build both Windows and Android artifacts and smoke-test an Android -> Windows
stream over a virtual-network IP.

# Hotspots

- Android `MediaProjection` and foreground-service permissions are sensitive to
  SDK and manifest changes.
- UDP packet format and HMAC verification must remain backward-compatible within
  protocol v1.
- Windows audio device selection should not block the UI thread.

# Parallel Development Notes

UI, Android capture, Windows playback, and Rust protocol work can be split into
separate branches. Avoid simultaneous edits to package manifests, generated
bridge files, and release scripts.
