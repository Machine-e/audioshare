import 'dart:io';

import 'package:flutter/services.dart';

class BluetoothDeviceInfo {
  const BluetoothDeviceInfo({
    required this.id,
    required this.name,
    this.isSelectedSink = false,
  });
  final String id;
  final String name;
  final bool isSelectedSink;

  factory BluetoothDeviceInfo.fromMap(Map<dynamic, dynamic> map) =>
      BluetoothDeviceInfo(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '未知设备',
        isSelectedSink: map['isSelectedSink'] == true,
      );
}

enum NativeSinkState { stopped, waitingForRoute, opened, disconnected, error }

class BluetoothSinkStatus {
  const BluetoothSinkStatus({required this.state, required this.message});
  final NativeSinkState state;
  final String message;

  factory BluetoothSinkStatus.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['mode']?.toString();
    final state = NativeSinkState.values
        .where((value) => value.name == raw)
        .firstOrNull;
    return BluetoothSinkStatus(
      state: state ?? NativeSinkState.error,
      message: state == null ? '原生端返回了无效状态。' : map['message']?.toString() ?? '',
    );
  }
}

class ExternalRouteBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.machinee.audioshare/external_route',
  );

  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() async {
    if (!Platform.isWindows) return const [];
    final value = await _channel.invokeMethod<dynamic>('listBluetoothDevices');
    if (value is! List) return const [];
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map(BluetoothDeviceInfo.fromMap)
        .toList();
  }

  Future<BluetoothSinkStatus> startBluetoothSink({
    required String deviceId,
  }) async => Platform.isWindows
      ? _status(
          await _channel.invokeMethod<dynamic>('startBluetoothSink', {
            'deviceId': deviceId,
          }),
        )
      : const BluetoothSinkStatus(
          state: NativeSinkState.error,
          message: '当前平台不支持蓝牙接收。',
        );

  Future<BluetoothSinkStatus> stopBluetoothSink() async => Platform.isWindows
      ? _status(await _channel.invokeMethod<dynamic>('stopBluetoothSink'))
      : const BluetoothSinkStatus(
          state: NativeSinkState.error,
          message: '当前平台不支持蓝牙接收。',
        );

  Future<BluetoothSinkStatus> waitBluetoothSinkStatusChange() async =>
      Platform.isWindows
      ? _status(
          await _channel.invokeMethod<dynamic>('waitBluetoothSinkStatusChange'),
        )
      : const BluetoothSinkStatus(
          state: NativeSinkState.error,
          message: '当前平台不支持蓝牙接收。',
        );

  Future<void> openBluetoothSettings() async {
    if (Platform.isWindows || Platform.isAndroid) {
      await _channel.invokeMethod<void>('openBluetoothSettings');
    }
  }

  static BluetoothSinkStatus _status(dynamic value) =>
      value is Map<dynamic, dynamic>
      ? BluetoothSinkStatus.fromMap(value)
      : const BluetoothSinkStatus(
          state: NativeSinkState.error,
          message: '原生端返回了无效状态。',
        );
}
