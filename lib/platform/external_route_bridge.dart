import 'dart:convert';
import 'dart:io' show File, Platform, Process, ProcessException;

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

class AuracastDataSection {
  const AuracastDataSection({required this.type, required this.bytes});

  final String type;
  final int bytes;

  factory AuracastDataSection.fromMap(Map<dynamic, dynamic> map) {
    return AuracastDataSection(
      type: map['type'] as String? ?? '',
      bytes: map['bytes'] as int? ?? 0,
    );
  }
}

class AuracastManufacturerData {
  const AuracastManufacturerData({
    required this.companyId,
    required this.bytes,
  });

  final String companyId;
  final int bytes;

  factory AuracastManufacturerData.fromMap(Map<dynamic, dynamic> map) {
    return AuracastManufacturerData(
      companyId: map['companyId'] as String? ?? '',
      bytes: map['bytes'] as int? ?? 0,
    );
  }
}

class AuracastBroadcast {
  const AuracastBroadcast({
    required this.address,
    required this.name,
    required this.rssi,
    required this.advertisementType,
    required this.events,
    required this.serviceUuids,
    required this.dataSections,
    required this.manufacturerData,
    required this.lastSeenIso,
    required this.isLikelyAuracast,
  });

  final String address;
  final String name;
  final int rssi;
  final String advertisementType;
  final int events;
  final List<String> serviceUuids;
  final List<AuracastDataSection> dataSections;
  final List<AuracastManufacturerData> manufacturerData;
  final String lastSeenIso;
  final bool isLikelyAuracast;

  factory AuracastBroadcast.fromMap(Map<dynamic, dynamic> map) {
    return AuracastBroadcast(
      address: map['address'] as String? ?? '',
      name: map['name'] as String? ?? '未命名广播',
      rssi: map['rssi'] as int? ?? 0,
      advertisementType: map['advertisementType'] as String? ?? '',
      events: map['events'] as int? ?? 0,
      serviceUuids: (map['serviceUuids'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      dataSections: (map['dataSections'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(AuracastDataSection.fromMap)
          .toList(growable: false),
      manufacturerData: (map['manufacturerData'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(AuracastManufacturerData.fromMap)
          .toList(growable: false),
      lastSeenIso: map['lastSeenIso'] as String? ?? '',
      isLikelyAuracast: map['isLikelyAuracast'] == true,
    );
  }
}

class AuracastScanResult {
  const AuracastScanResult({
    required this.mode,
    required this.message,
    required this.scanSeconds,
    required this.totalEvents,
    required this.matchedEvents,
    required this.allowExtendedAdvertisements,
    required this.joinApiAvailable,
    required this.joinApiNote,
    required this.broadcasts,
  });

  const AuracastScanResult.idle()
    : mode = 'idle',
      message = '尚未扫描 Auracast / LE Audio 广播',
      scanSeconds = 0,
      totalEvents = 0,
      matchedEvents = 0,
      allowExtendedAdvertisements = false,
      joinApiAvailable = false,
      joinApiNote = 'Windows 当前只做广播发现诊断，不承诺直接加入 Auracast 音频。',
      broadcasts = const [];

  final String mode;
  final String message;
  final int scanSeconds;
  final int totalEvents;
  final int matchedEvents;
  final bool allowExtendedAdvertisements;
  final bool joinApiAvailable;
  final String joinApiNote;
  final List<AuracastBroadcast> broadcasts;

  factory AuracastScanResult.fromMap(Map<dynamic, dynamic> map) {
    return AuracastScanResult(
      mode: map['mode'] as String? ?? 'unknown',
      message: map['message'] as String? ?? '',
      scanSeconds: map['scanSeconds'] as int? ?? 0,
      totalEvents: map['totalEvents'] as int? ?? 0,
      matchedEvents: map['matchedEvents'] as int? ?? 0,
      allowExtendedAdvertisements: map['allowExtendedAdvertisements'] == true,
      joinApiAvailable: map['joinApiAvailable'] == true,
      joinApiNote: map['joinApiNote'] as String? ?? '',
      broadcasts: (map['broadcasts'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(AuracastBroadcast.fromMap)
          .toList(growable: false),
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

  Future<AuracastScanResult> scanAuracastBroadcasts({int seconds = 12}) async {
    if (!Platform.isWindows) {
      return const AuracastScanResult(
        mode: 'unsupported',
        message: 'Auracast 广播扫描只支持 Windows 端。',
        scanSeconds: 0,
        totalEvents: 0,
        matchedEvents: 0,
        allowExtendedAdvertisements: false,
        joinApiAvailable: false,
        joinApiNote: '请在 Windows 端扫描，Android 端负责开启 HyperOS 音频广播。',
        broadcasts: [],
      );
    }
    final clampedSeconds = seconds.clamp(3, 90);
    final helper = File(
      _adjacentExecutablePath('audioshare_auracast_scanner.exe'),
    );
    if (!await helper.exists()) {
      return const AuracastScanResult(
        mode: 'error',
        message: '未找到 Auracast 扫描 helper，请使用完整 Windows portable 目录运行。',
        scanSeconds: 0,
        totalEvents: 0,
        matchedEvents: 0,
        allowExtendedAdvertisements: false,
        joinApiAvailable: false,
        joinApiNote:
            'audioshare.exe 需要和 audioshare_auracast_scanner.exe 放在同一目录。',
        broadcasts: [],
      );
    }
    try {
      final process = await Process.run(helper.path, [
        '--seconds',
        '$clampedSeconds',
      ]).timeout(Duration(seconds: clampedSeconds + 8));
      if (process.exitCode != 0) {
        return AuracastScanResult(
          mode: 'error',
          message:
              'Auracast 扫描 helper 退出码 ${process.exitCode}: ${process.stderr}',
          scanSeconds: clampedSeconds,
          totalEvents: 0,
          matchedEvents: 0,
          allowExtendedAdvertisements: false,
          joinApiAvailable: false,
          joinApiNote: '扫描进程异常退出，未进入 Auracast 音频接收流程。',
          broadcasts: const [],
        );
      }
      return AuracastScanResult.fromMap(_decodeStatusMap(process.stdout));
    } on ProcessException catch (error) {
      return AuracastScanResult(
        mode: 'error',
        message: '无法启动 Auracast 扫描 helper：${error.message}',
        scanSeconds: clampedSeconds,
        totalEvents: 0,
        matchedEvents: 0,
        allowExtendedAdvertisements: false,
        joinApiAvailable: false,
        joinApiNote: '请确认 Windows portable 目录完整，且 helper 未被安全软件拦截。',
        broadcasts: const [],
      );
    }
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

  static String _adjacentExecutablePath(String executableName) {
    final directory = File(Platform.resolvedExecutable).parent.path;
    return '$directory${Platform.pathSeparator}$executableName';
  }
}
