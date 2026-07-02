# Android Audio Routing Assessment

Date: 2026-07-01

## Current Implementation Status

- Android and Windows device connectivity has been confirmed.
- The current Android permission prompt is the system screen-capture prompt shown by `MediaProjectionManager.createScreenCaptureIntent()`.
- This prompt is expected for Android `AudioPlaybackCapture`: Android exposes system playback capture through the same MediaProjection consent flow used for screen sharing.
- A screen-sharing style prompt does not mean video capture is implemented or required, but the wording is controlled by Android and cannot be fully customized by the app.
- Android now builds `AudioPlaybackCaptureConfiguration`, creates `AudioRecord`, reads PCM16 frames, encodes Opus with Android `MediaCodec`, wraps frames in authenticated `ASH1` UDP packets, and sends them to the paired Windows receiver.
- Windows now accepts the v1 TCP control session, authenticates UDP packets, passes Opus payloads through `audioshare_core.dll`, uses a jitter buffer, decodes Opus to PCM, inserts silence on missing packets, and plays through `cpal`.
- The UI now separates TCP reachability from real stream state and shows runtime counters for capture, Opus, UDP send/receive, and playback activity.
- Android audio may still play through the phone speaker for arbitrary third-party apps because Android does not provide universal local speaker suppression for captured playback.

## Requirement Clarification

The desired behavior is:

- Android captures app/system playback audio.
- Android sends the captured audio stream to Windows.
- Android does not continue audible local speaker playback while streaming to Windows.
- If the Android-to-Windows connection disconnects, Android should automatically pause playback instead of continuing local playback.

## Technical Judgment

The implementation now contains the core Android-to-Windows audio pipeline. Remaining proof depends on real-device functional tests with capturable Android sources and a Windows output device.

Android `AudioPlaybackCapture` can capture eligible playback audio from other apps, but it does not automatically mute the original playback device. The source app may continue outputting to the phone speaker unless audio focus, routing, playback control, or a cooperating playback source is handled separately.

Because of this, the remaining product risk is routing/control, not just packet transport:

- Arbitrary third-party local playback cannot be forcibly muted by AudioShare.
- Apps that disallow playback capture or play DRM/protected content will produce no usable stream.
- Disconnect handling now stops the Android capture service and UDP sending after missed heartbeats, but pausing an external playback app still depends on that source app cooperating with Android audio focus.

## Likely Android Constraints

- Android does not provide a general-purpose API that lets one app forcibly mute all other apps' speaker output while still capturing their playback audio.
- `AudioPlaybackCapture` only captures apps that allow capture under Android policy.
- DRM/protected audio and apps that opt out of capture may not be capturable.
- Muting local playback reliably may require one of these approaches:
  - make AudioShare the playback app itself, then it can pause/mute its own player;
  - request/handle audio focus and pause cooperating apps where supported;
  - route device output to a silent or non-speaker sink if the OS/device supports it;
  - require the user to use a specific playback path that AudioShare can control;
  - accept that third-party apps may continue local playback unless they cooperate.

## Required Next Implementation Work

### Android Capture

- Validate on Android hardware that a known capturable source produces non-zero PCM frames.
- Validate that apps disallowing playback capture produce a clear empty/unsupported state instead of a false streaming state.
- Confirm foreground-service cleanup on user stop, permission revocation, and service destruction.

### Android Encoding and Transport

- Validate Android `MediaCodec` Opus availability on target devices.
- Confirm authenticated UDP sequence numbers and timestamps are monotonic during a real stream.
- Measure send errors and missed heartbeat behavior on virtual-network interruption.

### Windows Playback

- Validate playback on a real Windows output device using Android-captured input.
- Confirm output-device selection maps to actual `cpal` devices on target Windows machines.
- Exercise packet loss and out-of-order delivery beyond the current unit-level jitter tests.

### Local Playback Control

- Decide the product policy for phone-speaker behavior.
- If AudioShare controls the playback source, pause or mute local playback directly.
- If playback comes from third-party apps, implement best-effort audio-focus handling and clearly document unsupported cases.
- Add disconnect handling that pauses the controllable playback source when the Windows link drops.

## Current Product Risk

The requirement "Android does not play locally while streaming to Windows" may not be fully enforceable for arbitrary third-party Android apps without cooperation from the playback app or a supported system routing path. This should be treated as a core design constraint before implementing the full audio pipeline.

## Immediate Test Recommendation

- Use a controlled, known-capturable Android audio source and verify non-zero PCM, Opus frame count, UDP sent count, UDP received count, and Windows played-frame count all advance together.
- Test an app that opts out of playback capture and verify the UI reports the empty/unsupported capture condition.
- Interrupt the Windows receiver or virtual network and verify Android stops capture and UDP sending after the heartbeat timeout.
- Test third-party media apps separately to identify which apps allow playback capture and whether they honor audio-focus pause/mute behavior.
