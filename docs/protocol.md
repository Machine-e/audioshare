# AudioShare Protocol v1

AudioShare v1 uses a user-managed virtual network such as Tailscale or EasyTier.
The application assumes both devices can reach each other by virtual-network IP
and does not create or manage the VPN.

## Roles

- Windows listens on the configured TCP/UDP port and displays a pairing code.
- Android 12+ captures allowed system playback audio and pushes audio packets to Windows.
- Windows decodes Opus frames and plays them to the selected output device.

## Control Plane

The control plane is TCP. It handles:

- protocol version negotiation
- pairing code verification
- session id allocation
- audio configuration exchange
- start/stop/error messages

Every control hello includes `protocol_version = 1`. Incompatible versions must
fail clearly in the UI.

Current v1 control messages are newline-delimited UTF-8 text:

1. Android sends `Hello protocol_version=1 role=android`.
2. Windows replies `Hello protocol_version=1 role=windows`.
3. Android sends `Pair code=<pairing-code>`.
4. Windows replies
   `PairAccepted session_id=<id> token_hint=<hint> audio_key=<key>` or
   `PairRejected reason=<reason>`.
5. Android sends `StartStream` after `PairAccepted`.
6. Either side may send `StopStream` during teardown.

`AUDIOSHARE_PROBE <pairing-code>` is retained only as a reachability diagnostic.
An `AUDIOSHARE_OK` probe response must not be treated as audio-stream success.
Android also uses this probe as a heartbeat while streaming; repeated missed
heartbeats stop local capture and UDP sending.

## Audio Plane

The audio plane is UDP. Defaults:

- Opus codec
- 48 kHz sample rate
- stereo when available
- 20 ms frames
- 96 kbps target bitrate
- 80 ms jitter buffer

Each packet contains:

- magic `ASH1`
- protocol version
- session id
- sequence number
- capture timestamp
- Opus payload length
- Opus payload
- truncated HMAC-SHA256 authentication tag

Android captures playback with `AudioPlaybackCaptureConfiguration`, reads
48 kHz PCM16 frames from `AudioRecord`, encodes frames with Android's Opus
`MediaCodec`, then sends authenticated `ASH1` UDP packets.

## Security

Pairing starts with a one-time Windows pairing code. After successful pairing,
both sides use a shared session key to authenticate audio packets with a
truncated HMAC. This protects the stream against accidental cross-device traffic
inside the same virtual network.

## Android Local Playback Constraint

Android does not provide a universal, app-independent way for AudioShare to
force arbitrary third-party playback to mute or pause while capture continues.
AudioShare reports this as a compatibility constraint: eligible apps can be
captured, but local speaker suppression depends on the source app, route, and
device policy. The Android sender requests audio focus while streaming as a
best-effort hint, not as a guaranteed global mute.
