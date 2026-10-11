# AudioShare

AudioShare is a Bluetooth-only way to play Android media through a Windows PC.
Windows acts as a classic Bluetooth A2DP Sink. Android uses normal system
pairing and its media/audio-output selector. The Android app lists paired and
nearby PCs, remembers favorites/recent devices, provides receiver-state guidance,
a short test tone with manual confirmation.
Normal use does not require root, ADB or USB debugging.

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
- Android 12+; grant Nearby devices access for device selection and pairing.
- Both devices paired through the app's system confirmation or Bluetooth settings.

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

1. Open Windows Bluetooth settings to make the PC discoverable for first pairing.
   In Android AudioShare, grant Nearby devices access, tap +, then the circular
   PC card. Confirm the system pairing request on both devices. Already-paired
   PCs can be selected directly without opening Android Bluetooth settings.
2. Start AudioShare on Windows, select the paired phone, and enable Bluetooth
   audio reception.
3. On Android, choose the Windows PC in the system media-output, audio-output,
   or playback-device picker. The name varies by phone vendor.
4. Play media and keep AudioShare running while Windows receives audio.
5. Stop reception in AudioShare before removing the pairing.

Windows remembers the last explicitly selected phone but never starts reception
automatically. Closing the window offers hide-to-tray, exit, or cancel; hiding
keeps the receiver alive. Use the tray menu to show the window or exit.

Both apps offer saved light/dark/system appearance from the top-right menu.
The old system-volume slider has been removed. Independent transmission volume
and gain above 100% are not implemented in the current A2DP path; the Android
volume card reports this limitation. The app no longer changes Android's media
stream volume. The test tone stops after 2.5 seconds or when leaving the app.
Only the user can confirm hearing it on the PC. A separate authenticated,
encrypted Bluetooth RFCOMM channel reports Windows receiver state; it carries
no audio or remote commands. Both apps must be updated to use it. Unknown or
other-phone receiver targets are never treated as this phone's active route.
Bluetooth routing uses `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN`
(`neverForLocation`), without microphone or foreground-service access.
The optional updater uses Internet access and requests package installation.
Favorites/recent PCs stay on the phone. Pin a selected PC to the launcher or add
the AudioShare Quick Settings tile to reopen the last PC; neither shortcut
silently changes the global media route. Launcher/tile confirmation is system-owned.

See [the Bluetooth success and troubleshooting guide](docs/blue-tooth-success/README.md)
for the proven setup and recovery steps.
See [the phase-one PRD and execution plan](docs/phase-one-prd.md) for scope,
technical decisions and outstanding hardware acceptance checks.

## Limitations

- Bluetooth pairing alone is not enough. The phone must expose classic A2DP
  media audio, Windows must open the A2DP Sink, and the phone must select the PC
  as its active media output.
- Compatibility depends on the Windows Bluetooth adapter, driver, Windows
  version, and phone firmware.
- A paired device is not necessarily an active media route; Android must select
  the PC as its media output.
- Public Android APIs cannot silently force global A2DP output or bypass pairing
  confirmation. Android 14+ offers an in-app system output panel; Android 12–13
  uses the playing app's media-notification output picker, subject to OEM support.
- Bluetooth latency and quality are controlled by the system Bluetooth stacks.
- Calls, alarms, protected media, and non-media audio may route differently.
- AudioShare does not receive Auracast/LE Audio broadcasts and cannot stream
  audio over an IP network.
