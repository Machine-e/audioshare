import 'package:flutter/services.dart';

enum CompanionControlState { idle, connecting, connected, unavailable }

enum ReceiverTarget { thisPhone, otherPhone, unknown }

class CompanionDevice {
  const CompanionDevice({
    required this.id,
    required this.name,
    this.bonded = false,
    this.bonding = false,
    this.a2dpConnected = false,
    this.a2dpPlaying = false,
    this.a2dpStateKnown = false,
    this.favorite = false,
    this.recent = false,
  });
  final String id;
  final String name;
  final bool bonded,
      bonding,
      a2dpConnected,
      a2dpPlaying,
      a2dpStateKnown,
      favorite,
      recent;

  CompanionDevice withoutObservation() => CompanionDevice(
    id: id,
    name: name,
    bonded: bonded,
    bonding: bonding,
    favorite: favorite,
    recent: recent,
  );

  factory CompanionDevice.fromMap(Map<dynamic, dynamic> map) => CompanionDevice(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? '电脑',
    bonded: map['bonded'] == true,
    bonding: map['bonding'] == true,
    a2dpConnected: map['a2dpConnected'] == true,
    a2dpPlaying: map['a2dpPlaying'] == true,
    a2dpStateKnown: map['a2dpStateKnown'] == true,
    favorite: map['favorite'] == true,
    recent: map['recent'] == true,
  );
}

class CompanionSnapshot {
  const CompanionSnapshot({
    this.revision = 0,
    this.permission = false,
    this.bluetoothEnabled = false,
    this.discovering = false,
    this.devices = const [],
    this.selectedDeviceId,
    this.controlState = CompanionControlState.idle,
    this.receiverMode,
    this.receiverTarget = ReceiverTarget.unknown,
    this.message = '',
    this.outputSwitcherSupported = false,
  });
  final int revision;
  final bool permission, bluetoothEnabled, discovering, outputSwitcherSupported;
  final List<CompanionDevice> devices;
  final String? selectedDeviceId, receiverMode;
  final CompanionControlState controlState;
  final ReceiverTarget receiverTarget;
  final String message;

  CompanionSnapshot withoutReceiver() => CompanionSnapshot(
    revision: revision,
    permission: permission,
    bluetoothEnabled: bluetoothEnabled,
    discovering: false,
    devices: devices.map((d) => d.withoutObservation()).toList(),
    selectedDeviceId: selectedDeviceId,
    outputSwitcherSupported: outputSwitcherSupported,
  );

  factory CompanionSnapshot.fromMap(Map<dynamic, dynamic> map) =>
      CompanionSnapshot(
        revision: (map['revision'] as num?)?.toInt() ?? 0,
        permission: map['permission'] == true,
        bluetoothEnabled: map['bluetoothEnabled'] == true,
        discovering: map['discovering'] == true,
        devices: (map['devices'] as List? ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .map(CompanionDevice.fromMap)
            .toList(),
        selectedDeviceId: map['selectedDeviceId']?.toString(),
        controlState:
            CompanionControlState.values
                .where((v) => v.name == map['controlState'])
                .firstOrNull ??
            CompanionControlState.idle,
        receiverMode: map['receiverMode']?.toString(),
        receiverTarget:
            ReceiverTarget.values
                .where((v) => v.name == map['receiverTarget'])
                .firstOrNull ??
            ReceiverTarget.unknown,
        message: map['message']?.toString() ?? '',
        outputSwitcherSupported: map['outputSwitcherSupported'] == true,
      );
}

class CompanionBridge {
  static const _methods = MethodChannel('com.machinee.audioshare/companion');
  static const _events = EventChannel(
    'com.machinee.audioshare/companion_events',
  );

  Stream<CompanionSnapshot> get snapshots => _events
      .receiveBroadcastStream()
      .where((v) => v is Map)
      .map((v) => CompanionSnapshot.fromMap(v as Map<dynamic, dynamic>));
  Future<CompanionSnapshot> getSnapshot() => _snapshot('getSnapshot');
  Future<CompanionSnapshot> retryStatus() => _snapshot('retryStatus');
  Future<CompanionSnapshot> requestAccess() => _snapshot('requestAccess');
  Future<CompanionSnapshot> startDiscovery() => _snapshot('startDiscovery');
  Future<CompanionSnapshot> stopDiscovery() => _snapshot('stopDiscovery');
  Future<CompanionSnapshot> selectDevice(String deviceId) =>
      _snapshot('selectDevice', {'deviceId': deviceId});
  Future<CompanionSnapshot> setFavorite(String deviceId, bool favorite) =>
      _snapshot('setFavorite', {'deviceId': deviceId, 'favorite': favorite});
  Future<CompanionSnapshot> disconnectControl() =>
      _snapshot('disconnectControl');
  Future<bool> showOutputSwitcher() => _bool('showOutputSwitcher');
  Future<bool> pinShortcut(String deviceId) =>
      _bool('pinShortcut', {'deviceId': deviceId});
  Future<bool> addQuickTile() => _bool('addQuickTile');

  Future<CompanionSnapshot> _snapshot(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async => CompanionSnapshot.fromMap(
    (await _methods.invokeMethod<dynamic>(method, arguments))
        as Map<dynamic, dynamic>,
  );
  Future<bool> _bool(String method, [Map<String, dynamic>? arguments]) async =>
      await _methods.invokeMethod<bool>(method, arguments) ?? false;
}
