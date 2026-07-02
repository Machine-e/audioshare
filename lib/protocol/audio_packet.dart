import 'dart:convert';

import 'package:crypto/crypto.dart' show Hmac, sha256;

class AudioPacket {
  const AudioPacket({
    required this.sessionId,
    required this.sequence,
    required this.timestampMs,
    required this.payload,
  });

  final int sessionId;
  final int sequence;
  final int timestampMs;
  final List<int> payload;
}

class AudioPacketCodec {
  static const int _protocolVersion = 1;
  static const int _headerLength = 32;
  static const int _authTagLength = 16;

  static AudioPacket decode(List<int> bytes, String key) {
    if (bytes.length < _headerLength + _authTagLength) {
      throw const FormatException('packet is too short');
    }
    if (String.fromCharCodes(bytes.take(4)) != 'ASH1') {
      throw const FormatException('invalid magic');
    }
    if (_readInt(bytes, 4, 2) != _protocolVersion) {
      throw const FormatException('invalid protocol version');
    }

    final payloadLength = _readInt(bytes, 30, 2);
    final expectedLength = _headerLength + payloadLength + _authTagLength;
    if (bytes.length != expectedLength) {
      throw const FormatException('packet length does not match payload');
    }

    final bodyLength = bytes.length - _authTagLength;
    final expected = _hmacSha256(
      utf8.encode(key),
      bytes.sublist(0, bodyLength),
    );
    for (var index = 0; index < _authTagLength; index += 1) {
      if (bytes[bodyLength + index] != expected[index]) {
        throw const FormatException('authentication failed');
      }
    }

    return AudioPacket(
      sessionId: _readInt(bytes, 6, 8),
      sequence: _readInt(bytes, 14, 8),
      timestampMs: _readInt(bytes, 22, 8),
      payload: bytes.sublist(32, 32 + payloadLength),
    );
  }

  static List<int> encode(AudioPacket packet, String key) {
    if (packet.payload.length > 0xFFFF) {
      throw ArgumentError.value(
        packet.payload.length,
        'payload.length',
        'must fit in the v1 16-bit payload length field',
      );
    }
    final bytes = <int>[
      ...'ASH1'.codeUnits,
      0,
      _protocolVersion,
      ..._writeInt(packet.sessionId, 8),
      ..._writeInt(packet.sequence, 8),
      ..._writeInt(packet.timestampMs, 8),
      ..._writeInt(packet.payload.length, 2),
      ...packet.payload,
    ];
    final tag = _hmacSha256(utf8.encode(key), bytes);
    return [...bytes, ...tag.take(_authTagLength)];
  }

  static int _readInt(List<int> bytes, int start, int length) {
    var value = 0;
    for (var i = 0; i < length; i += 1) {
      value = (value << 8) | bytes[start + i];
    }
    return value;
  }

  static List<int> _writeInt(int value, int length) {
    return List<int>.generate(length, (index) {
      final shift = (length - index - 1) * 8;
      return (value >> shift) & 0xFF;
    });
  }

  static List<int> _hmacSha256(List<int> key, List<int> message) {
    return Hmac(sha256, key).convert(message).bytes;
  }
}
