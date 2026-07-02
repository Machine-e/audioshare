# Android Audio Routing Fix Plan

Date: 2026-07-01

## Objective

Bring AudioShare from the current connectivity/permission prototype to a real
Android-to-Windows audio streaming pipeline, while explicitly handling the
Android limitation that arbitrary third-party playback cannot always be muted or
paused by AudioShare.

This plan is based on the current repository implementation and the findings in
`docs/android-audio-routing-assessment.md`.

## Current Runtime Logic

- Flutter owns the main UI state in `lib/main.dart`.
- Android mode currently requests `RECORD_AUDIO`, notification permission, and
  MediaProjection consent through `MainActivity`.
- `AudioCaptureService` starts as a foreground service and creates a
  `MediaProjection`, but it does not yet create `AudioPlaybackCaptureConfiguration`
  or `AudioRecord`.
- Android streaming currently performs only a TCP reachability/probe handshake
  through Dart sockets before starting the foreground service.
- Windows mode currently opens a Dart `ServerSocket` and replies to
  `AUDIOSHARE_PROBE` / `AUDIOSHARE_STREAM_START`, but it does not yet receive
  UDP audio packets or play decoded PCM.
- `crates/audioshare_core` already contains useful Rust primitives for protocol
  packet auth, UDP sender/receiver, Opus encode/decode, jitter buffering, output
  device listing, and pairing-code normalization, but those primitives are not
  yet wired into Flutter/Android/Windows runtime paths.

## Design Decision

The fix must separate two product behaviors:

- **Required audio pipeline:** capture eligible Android playback, encode it,
  transport it, decode it, and play it on Windows.
- **Best-effort local playback control:** prevent or pause local phone playback
  only where Android policy and the playback source allow it.

For v1, do not claim that arbitrary third-party apps can be forcibly muted while
still being captured. The UI and docs should present this as a compatibility
constraint, not as a connection bug.

## Phase 1: Replace Probe-Only Streaming With a Real Session Contract

1. Extend the Dart Android start request so it passes the Windows host, TCP/UDP
   port, pairing code, bitrate, sample rate, frame size, and buffer target into
   the Android platform channel.
2. Replace the string-only `AUDIOSHARE_STREAM_START` handshake with the
   documented v1 control-plane messages:
   - `Hello`
   - `Pair`
   - `PairAccepted`
   - `StartStream`
   - `StopStream`
3. Decide whether the first implementation keeps the control plane in Dart or
   moves it into Rust. Prefer one owner for session state so pairing, session id,
   token/key derivation, and stream status are not duplicated.
4. Add explicit session states to Flutter:
   - permission granted
   - paired
   - capture active
   - packets sent
   - packets received
   - playback active
   - disconnected
5. Keep the existing TCP probe as a diagnostics action only. Do not let it mark
   the product as successfully streaming.

Validation:

- Windows can reject a wrong pairing code.
- Android receives a session id and shared audio auth key before sending UDP.
- UI distinguishes "reachable" from "audio streaming".

## Phase 2: Implement Android Playback Capture

1. In `AudioCaptureService`, build an `AudioPlaybackCaptureConfiguration` from
   the existing `MediaProjection`.
2. Create `AudioFormat` using the current product defaults:
   - 48 kHz
   - stereo when supported
   - PCM 16-bit
   - 20 ms frames
3. Create and start an `AudioRecord` with the playback-capture configuration.
4. Run capture on a dedicated background thread or coroutine owned by the
   foreground service.
5. Read exact frame-sized PCM chunks and report underrun, read error, and
   zero-frame conditions back to Flutter.
6. Stop `AudioRecord`, release it, and stop `MediaProjection` reliably on:
   - user stop
   - permission revocation
   - capture error
   - service destruction
   - network disconnect

Validation:

- A controlled capturable Android audio source produces non-zero PCM frames.
- Apps that disallow playback capture produce a clear unsupported/capture-empty
  state instead of a false streaming state.
- Foreground-service lifecycle remains stable on Android 12+ and Android 14+
  devices.

## Phase 3: Add Android Opus Encoding and UDP Sending

1. Choose the implementation path:
   - short-term: Kotlin uses Android `MediaCodec` Opus if device support is
     acceptable; or
   - preferred consistency path: expose `audioshare_core` through FFI and reuse
     the Rust `OpusCodec`, `AudioPacket`, and `UdpAudioSender`.
2. Convert captured PCM frames into Opus payloads using the session audio config.
3. Wrap each Opus frame in the protocol v1 `AudioPacket`:
   - magic `ASH1`
   - protocol version
   - session id
   - sequence number
   - capture timestamp
   - Opus payload
   - truncated HMAC tag
4. Send packets to the Windows UDP endpoint after `PairAccepted`.
5. Maintain sender metrics:
   - PCM frames captured
   - Opus frames encoded
   - UDP packets sent
   - send errors
   - last receiver heartbeat time

Validation:

- Unit-test packet encoding/decoding compatibility between Android path and
  `audioshare_core`.
- Confirm packet sequence numbers and timestamps are monotonic.
- Confirm wrong auth keys are rejected by the receiver.

## Phase 4: Implement Windows Receive, Decode, Jitter Buffer, and Playback

1. Replace the Dart `ServerSocket` streaming placeholder with a real Windows
   receiver runtime.
2. Bind TCP for control and UDP for audio on the configured port.
3. On `PairAccepted`, create a receiver session with the negotiated audio config
   and auth key.
4. Use `UdpAudioReceiver` to authenticate and parse incoming `AudioPacket`s.
5. Feed packets into `JitterBuffer` using the configured buffer target.
6. Decode Opus payloads to PCM with `OpusCodec`.
7. Play PCM through the selected Windows output device using `cpal`.
8. Add underrun handling:
   - insert silence for missing packets
   - keep playback clock stable
   - surface underrun count and jitter in UI

Validation:

- Windows can play a generated Opus sine/test stream before using Android input.
- Windows can play Android-captured audio over the virtual-network IP.
- Packet loss and out-of-order delivery do not crash playback.

## Phase 5: Disconnect Detection and Stop/Pause Behavior

1. Add heartbeat/keepalive messages on the control plane or receiver status
   acknowledgements at a fixed interval.
2. Define disconnect thresholds:
   - warning after short missed-heartbeat window
   - stop stream after hard timeout
3. On Android timeout:
   - stop UDP sending
   - stop `AudioRecord`
   - stop/release `MediaProjection`
   - update Flutter state to disconnected
4. If AudioShare owns the playback source in a future controlled-player mode,
   pause that source immediately on disconnect.
5. For third-party playback, request audio focus where useful and document that
   pause/mute depends on the source app honoring focus changes.

Validation:

- Turning off Windows receiver stops Android capture within the timeout.
- Killing the Android service stops capture and clears the notification.
- UI shows "disconnected" instead of continuing fake stats.

## Phase 6: Local Phone Speaker Policy

1. Add an explicit compatibility section in the UI:
   - "AudioShare can capture eligible apps."
   - "Android may still play audio locally unless the source app or device route
     allows suppression."
2. Implement best-effort audio-focus behavior:
   - request focus while streaming
   - use focus loss callbacks to pause only AudioShare-owned playback
   - surface when focus request is denied
3. Add a future optional "controlled playback source" mode if the product needs
   guaranteed pause/mute semantics.
4. Do not implement misleading global mute logic for arbitrary apps unless a
   specific supported routing path is proven on target devices.

Validation:

- Third-party app behavior is tested and documented per app/device.
- The app never claims local speaker suppression when it cannot enforce it.

## Phase 7: UI and Diagnostics Updates

1. Replace simulated stats in `AudioShareController._startStats()` with runtime
   stats from the actual Android sender and Windows receiver.
2. Show separate status rows for:
   - TCP control connected
   - MediaProjection authorized
   - AudioRecord capturing
   - Opus encoding
   - UDP packets sent/received
   - Windows playback active
3. Add actionable error messages for:
   - app disallows playback capture
   - no PCM frames captured
   - UDP blocked by firewall/VPN
   - auth failure
   - output device unavailable
   - receiver underrun
4. Keep "Test connection" as a network diagnostic and label it separately from
   "Start audio stream".

Validation:

- A successful TCP probe no longer displays as audio streaming.
- Streaming status requires non-zero received/played audio frames.

## Phase 8: Test Matrix

Run these milestones in order:

1. Rust unit tests:
   - protocol round-trip/auth failure
   - jitter ordering and missing packet behavior
   - codec encode/decode smoke test
2. Windows local synthetic stream:
   - generated PCM -> Opus -> UDP packet -> receiver -> decode -> output device
3. Android controlled source:
   - known capturable playback -> `AudioRecord` non-zero PCM -> UDP send
4. End-to-end virtual-network stream:
   - Android sender -> Windows receiver over Tailscale/EasyTier IP
5. Disconnect tests:
   - close Windows receiver
   - disable virtual network
   - lock Android screen
   - stop Android foreground service
6. Compatibility tests:
   - capturable media app
   - app that opts out of capture
   - DRM/protected content
   - Bluetooth/headset route
   - phone speaker route

## Suggested Implementation Order

1. Wire real session/control state and remove fake streaming success.
2. Implement Android `AudioRecord` playback capture and PCM diagnostics.
3. Implement Windows synthetic UDP receive/decode/playback path.
4. Add Android encode/send using the same packet format.
5. Connect end-to-end and replace simulated stats.
6. Add disconnect handling and best-effort pause/control behavior.
7. Update user-facing docs for Android capture limitations.

## Files Likely To Change

- `lib/main.dart`
- `lib/platform/audio_capture_bridge.dart`
- `android/app/src/main/kotlin/com/machinee/audioshare/MainActivity.kt`
- `android/app/src/main/kotlin/com/machinee/audioshare/AudioCaptureService.kt`
- `android/app/src/main/AndroidManifest.xml`
- `crates/audioshare_core/src/protocol.rs`
- `crates/audioshare_core/src/transport.rs`
- `crates/audioshare_core/src/codec.rs`
- `crates/audioshare_core/src/jitter.rs`
- `crates/audioshare_core/src/audio.rs`
- Windows native/Flutter bridge files, depending on the chosen Rust FFI wiring
- `docs/protocol.md`
- `README.md`

## Open Technical Questions

- Whether to expose `audioshare_core` to Flutter/Android/Windows through FFI now,
  or first implement a narrower native bridge for the audio runtime.
- Whether Android Opus encoding should use Rust `opus` everywhere or Android
  platform codecs for the sender.
- Whether Windows control/audio runtime should live mostly in Rust with a thin
  Flutter bridge, or remain partly in Dart.
- Which controlled Android audio source should be used as the first reliable
  test milestone.
- Which third-party apps are in the supported v1 compatibility list.

## Definition of Done

The issues in `android-audio-routing-assessment.md` are considered fixed when:

- Android reads non-zero PCM frames from `AudioRecord` using
  `AudioPlaybackCaptureConfiguration`.
- Android encodes those frames to Opus and sends authenticated UDP packets.
- Windows authenticates, buffers, decodes, and plays the received audio.
- UI stats come from real sender/receiver counters, not simulated timers.
- Disconnect stops Android capture and sending within the defined timeout.
- Local playback behavior is honestly enforced only for controllable sources and
  clearly documented as best-effort for arbitrary third-party apps.

The concrete automated and hardware validation checklist is maintained in
`docs/android-audio-routing-validation-checklist.md`.
