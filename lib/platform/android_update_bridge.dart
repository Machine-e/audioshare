import 'package:flutter/services.dart';

class AndroidUpdateInfo {
  const AndroidUpdateInfo({
    required this.available,
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
  });

  final bool available;
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;

  factory AndroidUpdateInfo.fromMap(Map<Object?, Object?> map) {
    return AndroidUpdateInfo(
      available: map['available'] == true,
      currentVersion: map['currentVersion'] as String? ?? '',
      latestVersion: map['latestVersion'] as String? ?? '',
      downloadUrl: map['downloadUrl'] as String? ?? '',
    );
  }
}

class AndroidUpdateBridge {
  static const _channel = MethodChannel('com.machinee.audioshare/update');

  Future<AndroidUpdateInfo> checkForUpdate() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'checkForUpdate',
    );
    if (result == null) {
      throw StateError('更新检查没有返回结果');
    }
    return AndroidUpdateInfo.fromMap(result);
  }

  Future<void> downloadAndInstall(String downloadUrl) async {
    await _channel.invokeMethod<void>('downloadAndInstall', {
      'url': downloadUrl,
    });
  }
}
