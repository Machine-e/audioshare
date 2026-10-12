import 'package:flutter/services.dart';

class AndroidDownloadProgress {
  const AndroidDownloadProgress({
    this.received = 0,
    this.total = 0,
    this.installing = false,
  });

  final int received, total;
  final bool installing;
  double? get fraction => total > 0 ? (received / total).clamp(0, 1) : null;

  factory AndroidDownloadProgress.fromMap(Map<Object?, Object?> map) =>
      AndroidDownloadProgress(
        received: (map['received'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt() ?? 0,
        installing: map['stage'] == 'installing',
      );
}

class AndroidUpdateInfo {
  const AndroidUpdateInfo({
    required this.available,
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    this.message = '',
  });

  final bool available;
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String message;

  factory AndroidUpdateInfo.fromMap(Map<Object?, Object?> map) {
    return AndroidUpdateInfo(
      available: map['available'] == true,
      currentVersion: map['currentVersion'] as String? ?? '',
      latestVersion: map['latestVersion'] as String? ?? '',
      downloadUrl: map['downloadUrl'] as String? ?? '',
      message: map['message'] as String? ?? '',
    );
  }
}

class AndroidUpdateBridge {
  static const _channel = MethodChannel('com.machinee.audioshare/update');
  static const _events = EventChannel(
    'com.machinee.audioshare/update_progress',
  );
  static int _nextRequest = 0;

  Future<AndroidUpdateInfo> checkForUpdate() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'checkForUpdate',
    );
    if (result == null) {
      throw StateError('更新检查没有返回结果');
    }
    return AndroidUpdateInfo.fromMap(result);
  }

  Future<void> downloadAndInstall(
    String downloadUrl, {
    void Function(AndroidDownloadProgress)? onProgress,
  }) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextRequest++}';
    final subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Map && event['requestId'] == requestId) {
          onProgress?.call(AndroidDownloadProgress.fromMap(event));
        }
      },
      onError: (Object _) {
        /* The method result reports download failures. */
      },
    );
    try {
      await _channel.invokeMethod<void>('downloadAndInstall', {
        'url': downloadUrl,
        'requestId': requestId,
      });
    } finally {
      await subscription.cancel();
    }
  }
}
