import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class ExternalRouteDevice {
  const ExternalRouteDevice({
    required this.id,
    required this.name,
    required this.isConnected,
  });

  final String id;
  final String name;
  final bool isConnected;

  factory ExternalRouteDevice.fromMap(Map<dynamic, dynamic> map) {
    return ExternalRouteDevice(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '未命名蓝牙设备',
      isConnected: map['isConnected'] == true,
    );
  }
}

class ExternalRouteStatus {
  const ExternalRouteStatus({required this.mode, required this.message});

  final String mode;
  final String message;

  factory ExternalRouteStatus.fromMap(Map<dynamic, dynamic> map) {
    return ExternalRouteStatus(
      mode: map['mode'] as String? ?? 'unknown',
      message: map['message'] as String? ?? '',
    );
  }
}

class ExternalRouteBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.machinee.audioshare/external_route',
  );

  Future<List<ExternalRouteDevice>> listBluetoothDevices() async {
    if (!Platform.isWindows) return const [];
    final result = await _invokeExternalRoute<dynamic>('listBluetoothDevices');
    return _decodeDeviceList(result)
        .map(
          (item) => ExternalRouteDevice.fromMap(item as Map<dynamic, dynamic>),
        )
        .where((device) => device.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<ExternalRouteStatus> startBluetoothSink(String deviceId) async {
    if (!Platform.isWindows) {
      return const ExternalRouteStatus(
        mode: 'unsupported',
        message: '蓝牙音频接收只支持 Windows 端。',
      );
    }
    final result = await _invokeExternalRoute<dynamic>('startBluetoothSink', {
      'deviceId': deviceId,
    });
    return ExternalRouteStatus.fromMap(_decodeStatusMap(result));
  }

  Future<ExternalRouteStatus> stopBluetoothSink() async {
    if (!Platform.isWindows) {
      return const ExternalRouteStatus(
        mode: 'stopped',
        message: '未在 Windows 运行',
      );
    }
    final result = await _invokeExternalRoute<dynamic>('stopBluetoothSink');
    return ExternalRouteStatus.fromMap(_decodeStatusMap(result));
  }

  Future<ExternalRouteStatus> openWirelessDisplay() async {
    if (!Platform.isWindows) {
      return const ExternalRouteStatus(
        mode: 'unsupported',
        message: '无线显示接收入口只支持 Windows 端。',
      );
    }
    final result = await _invokeExternalRoute<dynamic>('openWirelessDisplay');
    return ExternalRouteStatus.fromMap(_decodeStatusMap(result));
  }

  Future<bool> isWindowsOutputActive() async {
    if (!Platform.isWindows) return false;
    return await _invokeExternalRoute<bool>('isWindowsOutputActive') ?? false;
  }

  static Future<T?> _invokeExternalRoute<T>(
    String method, [
    Object? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  static List<dynamic> _decodeDeviceList(dynamic result) {
    final decoded = _decodeJsonIfNeeded(result);
    if (decoded == null) return const [];
    if (decoded is List<dynamic>) return decoded;
    if (decoded is Map<dynamic, dynamic>) return [decoded];
    return const [];
  }

  static Map<dynamic, dynamic> _decodeStatusMap(dynamic result) {
    final decoded = _decodeJsonIfNeeded(result);
    if (decoded is Map<dynamic, dynamic>) return decoded;
    return const {'mode': 'error', 'message': '外部路由 helper 返回了不可识别的结果'};
  }

  static dynamic _decodeJsonIfNeeded(dynamic value) {
    if (value is String) {
      var trimmed = value.trim();
      if (trimmed.startsWith('\uFEFF')) {
        trimmed = trimmed.substring(1).trim();
      }
      if (trimmed.isEmpty) return null;
      return jsonDecode(trimmed);
    }
    return value;
  }
}
