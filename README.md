# AudioShare

AudioShare is a Bluetooth-only way to play Android media through a Windows PC.
Windows acts as a classic Bluetooth A2DP Sink. Android uses normal system
pairing and its media/audio-output selector; the Android app only opens
Bluetooth settings.

After startup, `waitingForRoute` means the receiver is ready but the phone has
not selected this PC as media output. Only a real Windows `Opened` event becomes
`opened`; a later close becomes `disconnected`. Changes are event-driven and
cached across waiter reattachment rather than periodically polled.

AudioShare does **not** use Tailscale, EasyTier, TCP/UDP streaming, Opus,
Auracast, screen casting, MediaProjection, or Android audio capture.

## Requirements

- Windows 11 with a Bluetooth adapter/driver that supports A2DP Sink through
  `AudioPlaybackConnection`.
- An Android phone with classic Bluetooth media output.
- Both devices paired in their system Bluetooth settings.

## Build

Use the local Flutter SDK when Flutter is not on `PATH`:

```powershell
E:\Programs\flutter\bin\flutter.bat pub get
E:\Programs\flutter\bin\flutter.bat test
E:\Programs\flutter\bin\flutter.bat analyze
E:\Programs\flutter\bin\flutter.bat build windows --release
E:\Programs\flutter\bin\flutter.bat build apk --release
```

Portable artifacts can be packaged with:

```powershell
.\scripts\build_windows_portable.ps1
.\scripts\build_android_apk.ps1
```

## Use

1. Pair the Android phone and Windows PC using system Bluetooth settings.
2. Start AudioShare on Windows, select the paired phone, and enable Bluetooth
   audio reception.
3. On Android, choose the Windows PC in the system media-output, audio-output,
   or playback-device picker. The name varies by phone vendor.
4. Play media and keep AudioShare running while Windows receives audio.
5. Stop reception in AudioShare before removing the pairing.

See [the Bluetooth success and troubleshooting guide](docs/blue-tooth-success/README.md)
for the proven setup and recovery steps.

## Limitations

- Bluetooth pairing alone is not enough. The phone must expose classic A2DP
  media audio, Windows must open the A2DP Sink, and the phone must select the PC
  as its active media output.
- Compatibility depends on the Windows Bluetooth adapter, driver, Windows
  version, and phone firmware.
- A paired device is not necessarily an active media route; Android must select
  the PC as its media output.
- Bluetooth latency and quality are controlled by the system Bluetooth stacks.
- Calls, alarms, protected media, and non-media audio may route differently.
- AudioShare does not receive Auracast/LE Audio broadcasts and cannot stream
  audio over an IP network.
