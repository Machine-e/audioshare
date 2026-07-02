import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class CaptureStartConfig {
  const CaptureStartConfig({
    required this.host,
    required this.controlPort,
    required this.udpPort,
    required this.pairingCode,
    required this.sessionId,
    required this.audioAuthKey,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.frameMs,
    required this.bufferMs,
    this.channels = 2,
  });

  final String host;
  final int controlPort;
  final int udpPort;
  final String pairingCode;
  final int sessionId;
  final String audioAuthKey;
  final int bitrateKbps;
  final int sampleRate;
  final int frameMs;
  final int bufferMs;
  final int channels;

  Map<String, Object> toMap() => {
    'host': host,
    'controlPort': controlPort,
    'udpPort': udpPort,
    'pairingCode': pairingCode,
    'sessionId': sessionId,
    'audioAuthKey': audioAuthKey,
    'bitrateKbps': bitrateKbps,
    'sampleRate': sampleRate,
    'frameMs': frameMs,
    'bufferMs': bufferMs,
    'channels': channels,
  };
}

class CaptureRuntimeStats {
  const CaptureRuntimeStats({
    required this.captureActive,
    required this.mediaProjectionAuthorized,
    required this.audioRecordCapturing,
    required this.opusEncoding,
    required this.pcmFramesCaptured,
    required this.opusFramesEncoded,
    required this.udpPacketsSent,
    required this.sendErrors,
    required this.zeroFrames,
    required this.readErrors,
    required this.underruns,
    required this.lastMessage,
  });

  final bool captureActive;
  final bool mediaProjectionAuthorized;
  final bool audioRecordCapturing;
  final bool opusEncoding;
  final int pcmFramesCaptured;
  final int opusFramesEncoded;
  final int udpPacketsSent;
  final int sendErrors;
  final int zeroFrames;
  final int readErrors;
  final int underruns;
  final String lastMessage;

  factory CaptureRuntimeStats.fromMap(Map<dynamic, dynamic> map) {
    int intValue(String key) => (map[key] as num?)?.toInt() ?? 0;
    bool boolValue(String key) => map[key] == true;
    return CaptureRuntimeStats(
      captureActive: boolValue('captureActive'),
      mediaProjectionAuthorized: boolValue('mediaProjectionAuthorized'),
      audioRecordCapturing: boolValue('audioRecordCapturing'),
      opusEncoding: boolValue('opusEncoding'),
      pcmFramesCaptured: intValue('pcmFramesCaptured'),
      opusFramesEncoded: intValue('opusFramesEncoded'),
      udpPacketsSent: intValue('udpPacketsSent'),
      sendErrors: intValue('sendErrors'),
      zeroFrames: intValue('zeroFrames'),
      readErrors: intValue('readErrors'),
      underruns: intValue('underruns'),
      lastMessage: map['lastMessage'] as String? ?? '',
    );
  }
}

class AudioCaptureBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.machinee.audioshare/audio_capture',
  );
  static const EventChannel _events = EventChannel(
    'com.machinee.audioshare/audio_capture_events',
  );

  Stream<CaptureRuntimeStats> runtimeStats() {
    if (!Platform.isAndroid) return const Stream.empty();
    return _events.receiveBroadcastStream().map((event) {
      return CaptureRuntimeStats.fromMap(event as Map<dynamic, dynamic>);
    });
  }

  Future<bool> requestCapturePermission() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestCapturePermission') ??
        false;
  }

  Future<void> startForegroundService(CaptureStartConfig config) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>(
      'startForegroundCaptureService',
      config.toMap(),
    );
  }

  Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundCaptureService');
  }

  Future<void> openBluetoothSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openBluetoothSettings');
  }

  Future<void> openCastSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openCastSettings');
  }
}
