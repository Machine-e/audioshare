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

## Security

Pairing starts with a one-time Windows pairing code. After successful pairing,
both sides use a shared session key to authenticate audio packets with a
truncated HMAC. This protects the stream against accidental cross-device traffic
inside the same virtual network.
