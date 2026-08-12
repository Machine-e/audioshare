# Project

AudioShare is a Flutter application for Bluetooth-only Android-to-Windows audio.
Windows is a classic Bluetooth A2DP Sink; Android uses system pairing and media
output routing. The app does not capture, encode, or transport Android audio.

# Dev Commands

```powershell
E:\Programs\flutter\bin\flutter.bat pub get
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat analyze
E:\Programs\flutter\bin\flutter.bat build windows --release
E:\Programs\flutter\bin\flutter.bat build apk --release
```

# Architecture

- `lib/` contains Flutter UI and app state.
- `windows/` manages the Windows `AudioPlaybackConnection` A2DP Sink.
- Android native code exposes only the system Bluetooth-settings action through
  `com.machinee.audioshare/external_route`.
- `docs/blue-tooth-success/README.md` is the canonical setup and troubleshooting
  guide.
- `scripts/` contains Windows portable and Android APK packaging helpers.

# Validation Expectations

Run Flutter tests and analysis after UI/state changes. Build the affected target
after native changes. For Bluetooth behavior, pair a real Android phone, select
the PC as media output, and confirm sustained playback through Windows.

# Hotspots

- Windows A2DP Sink support varies by Bluetooth adapter, driver, and OS build.
- Keep the Windows `AudioPlaybackConnection` object alive for the whole session.
- Android should not request capture, microphone, networking, notification, or
  foreground-service permissions for Bluetooth routing.

# Parallel Development Notes

Avoid simultaneous edits to Flutter state, Windows route-channel code, package
manifests, generated files, and release scripts.
