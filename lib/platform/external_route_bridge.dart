import 'dart:io';

import 'package:flutter/services.dart';

class BluetoothDeviceInfo {
  const BluetoothDeviceInfo({
    required this.id,
    required this.name,
    required this.isConnected,
  });

  final String id;
  final String name;
  final bool isConnected;

  factory BluetoothDeviceInfo.fromMap(Map<dynamic, dynamic> map) =>
      BluetoothDeviceInfo(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '未知设备',
        isConnected: map['isConnected'] == true,
      );
}

class BluetoothSinkStatus {
  const BluetoothSinkStatus({required this.mode, required this.message});

  final String mode;
  final String message;

  bool get isConnected => const {
    'connected',
    'running',
    'started',
    'active',
    'enabled',
    'playing',
  }.contains(mode.toLowerCase());

  factory BluetoothSinkStatus.fromMap(Map<dynamic, dynamic> map) =>
      BluetoothSinkStatus(
        mode: map['mode']?.toString() ?? 'unknown',
        message: map['message']?.toString() ?? '',
      );
}

class ExternalRouteBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.machinee.audioshare/external_route',
  );

  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() async {
    if (!Platform.isWindows) return const [];
    final dynamic value = await _channel.invokeMethod<dynamic>(
      'listBluetoothDevices',
    );
    if (value is! List) return const [];
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map(BluetoothDeviceInfo.fromMap)
        .toList();
  }

  Future<BluetoothSinkStatus> startBluetoothSink({
    required String deviceId,
  }) async {
    if (!Platform.isWindows) {
      return const BluetoothSinkStatus(
        mode: 'unsupported',
        message: '当前平台不支持蓝牙接收。',
      );
    }
    return _status(
      await _channel.invokeMethod<dynamic>('startBluetoothSink', {
        'deviceId': deviceId,
      }),
    );
  }

  Future<BluetoothSinkStatus> stopBluetoothSink() async {
    if (!Platform.isWindows) {
      return const BluetoothSinkStatus(
        mode: 'unsupported',
        message: '当前平台不支持蓝牙接收。',
      );
    }
    return _status(await _channel.invokeMethod<dynamic>('stopBluetoothSink'));
  }

  Future<BluetoothSinkStatus> getBluetoothSinkStatus() async {
    if (!Platform.isWindows) {
      return const BluetoothSinkStatus(
        mode: 'unsupported',
        message: '当前平台不支持蓝牙接收。',
      );
    }
    return _status(
      await _channel.invokeMethod<dynamic>('getBluetoothSinkStatus'),
    );
  }

  Future<void> openBluetoothSettings() async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openBluetoothSettings');
  }

  static BluetoothSinkStatus _status(dynamic value) {
    if (value is Map<dynamic, dynamic>) {
      return BluetoothSinkStatus.fromMap(value);
    }
    return const BluetoothSinkStatus(mode: 'unknown', message: '原生端返回了无效状态。');
  }
}
