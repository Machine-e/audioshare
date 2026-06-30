import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class AudioCaptureBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.machinee.audioshare/audio_capture',
  );

  Future<void> startForegroundService() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('startForegroundCaptureService');
  }

  Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundCaptureService');
  }
}
