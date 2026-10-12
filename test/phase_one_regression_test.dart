import 'dart:async';

import 'package:audioshare/main.dart';
import 'package:audioshare/platform/companion_bridge.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' as existing;

class RegressionCompanion extends CompanionBridge {
  static const value = CompanionSnapshot(permission: true);
  @override
  Stream<CompanionSnapshot> get snapshots => const Stream.empty();
  @override
  Future<CompanionSnapshot> getSnapshot() async => value;
}

class RegressionBridge extends existing.FakeBridge {
  final calls = <String>[];
  final starts = <String>[];
  Object? preferenceError;
  Object? settingsError;
  Object? setVolumeError;
  Completer<void>? blockedWrite;
  Completer<void>? blockedPlay;
  final volumeReads = <Future<MediaVolume>>[];

  @override
  Future<String?> readPreferredDevice() async {
    calls.add('preference');
    if (preferenceError != null) throw preferenceError!;
    return super.readPreferredDevice();
  }

  @override
  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() async {
    calls.add('devices');
    return super.listBluetoothDevices();
  }

  @override
  Future<void> writePreferredDevice(String deviceId) async {
    calls.add('write:$deviceId');
    if (deviceId == 'b' && blockedWrite != null) await blockedWrite!.future;
    await super.writePreferredDevice(deviceId);
  }

  @override
  Future<BluetoothSinkStatus> startBluetoothSink({
    required String deviceId,
  }) async {
    starts.add(deviceId);
    return super.startBluetoothSink(deviceId: deviceId);
  }

  @override
  Future<void> openBluetoothSettings() async {
    if (settingsError != null) throw settingsError!;
    await super.openBluetoothSettings();
  }

  @override
  Future<MediaVolume> getMediaVolume() {
    if (volumeReads.isNotEmpty) return volumeReads.removeAt(0);
    return super.getMediaVolume();
  }

  @override
  Future<MediaVolume> setMediaVolume(int value) async {
    setVolumes.add(value);
    if (setVolumeError != null) throw setVolumeError!;
    return MediaVolume(current: value, max: mediaVolume.max, fixed: false);
  }

  @override
  Future<void> playTestTone() async {
    toneStarts++;
    if (blockedPlay != null) await blockedPlay!.future;
  }
}

void main() {
  test(
    'preference read and enumeration start independently in either order',
    () async {
      final preferenceFirst = RegressionBridge()
        ..pendingRefresh = Completer<List<BluetoothDeviceInfo>>();
      final firstController = AudioShareController(
        bridge: preferenceFirst,
        isWindows: true,
      );
      final firstInit = firstController.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(preferenceFirst.calls, ['preference', 'devices']);
      preferenceFirst.pendingRefresh!.complete(preferenceFirst.devices);
      await firstInit;

      final devicesFirst = RegressionBridge()
        ..pendingPreference = Completer<String?>();
      final secondController = AudioShareController(
        bridge: devicesFirst,
        isWindows: true,
      );
      final secondInit = secondController.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(secondController.devices, devicesFirst.devices);
      expect(secondController.selectedDeviceId, isNull);
      devicesFirst.pendingPreference!.complete('phone');
      await secondInit;
      expect(secondController.selectedDeviceId, 'phone');
      firstController.dispose();
      secondController.dispose();
    },
  );

  testWidgets('dropdown value follows a late cached preference', (
    tester,
  ) async {
    final bridge = RegressionBridge()..pendingPreference = Completer<String?>();
    await tester.pumpWidget(
      AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
    );
    await tester.pump();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('device-dropdown')),
          )
          .value,
      isNull,
    );
    bridge.pendingPreference!.complete('phone');
    await tester.pump();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('device-dropdown')),
          )
          .value,
      'phone',
    );
  });

  test(
    'missing memory does not select another device or auto-start on return',
    () async {
      final bridge = RegressionBridge()
        ..preferred = 'remembered'
        ..devices = const [BluetoothDeviceInfo(id: 'other', name: 'Other')];
      final controller = AudioShareController(bridge: bridge, isWindows: true);
      await controller.initialize();
      expect(controller.selectedDeviceId, isNull);
      await controller.start();
      expect(bridge.starts, isEmpty);
      bridge.devices = const [
        BluetoothDeviceInfo(id: 'remembered', name: 'Remembered'),
        BluetoothDeviceInfo(id: 'other', name: 'Other'),
      ];
      await controller.refreshDevices();
      expect(controller.selectedDeviceId, 'remembered');
      expect(bridge.starts, isEmpty);
      controller.dispose();
    },
  );

  test('preference writes are serial and C waits behind blocked B', () async {
    final bridge = RegressionBridge()..blockedWrite = Completer<void>();
    final controller = AudioShareController(bridge: bridge, isWindows: true);
    controller.selectDevice('b');
    controller.selectDevice('c');
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls.where((call) => call.startsWith('write:')), [
      'write:b',
    ]);
    bridge.blockedWrite!.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls.where((call) => call.startsWith('write:')), [
      'write:b',
      'write:c',
    ]);
    controller.dispose();
  });

  test('active session rejects another start and device change', () async {
    final bridge = RegressionBridge();
    final controller = AudioShareController(bridge: bridge, isWindows: true);
    await controller.initialize();
    controller.selectDevice('phone');
    await controller.start();
    expect(controller.phase, SinkPhase.waitingForRoute);
    controller.selectDevice('other');
    await controller.start();
    expect(controller.preferredDeviceId, 'phone');
    expect(bridge.starts, ['phone']);
    controller.dispose();
  });

  test(
    'preference and settings errors do not block controls or alter phase',
    () async {
      final bridge = RegressionBridge()
        ..preferenceError = Exception('cache')
        ..settingsError = Exception('settings');
      final controller = AudioShareController(bridge: bridge, isWindows: true);
      await controller.initialize();
      expect(controller.devices, isNotEmpty);
      expect(controller.phase, SinkPhase.stopped);
      await controller.openBluetoothSettings();
      expect(controller.phase, SinkPhase.stopped);
      expect(controller.deviceError, contains('settings'));
      controller.selectDevice('phone');
      await controller.start();
      expect(controller.phase, SinkPhase.waitingForRoute);
      controller.dispose();
    },
  );

  testWidgets('failed reread removes stale Android volume controls', (
    tester,
  ) async {
    final bridge = RegressionBridge()
      ..volumeReads.add(
        Future.value(const MediaVolume(current: 4, max: 10, fixed: false)),
      );
    await tester.pumpWidget(
      AudioShareApp(
        bridge: bridge,
        companionBridge: RegressionCompanion(),
        platform: TargetPlatform.android,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('media-volume-slider')), findsOneWidget);
    bridge.volumeReads.add(Future.error(Exception('second read')));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(const Key('media-volume-slider')), findsNothing);
    expect(find.textContaining('second read'), findsOneWidget);
  });

  testWidgets('failed set restores draft and max zero disables slider', (
    tester,
  ) async {
    final bridge = RegressionBridge()..setVolumeError = Exception('set failed');
    await tester.pumpWidget(
      AudioShareApp(
        bridge: bridge,
        companionBridge: RegressionCompanion(),
        platform: TargetPlatform.android,
      ),
    );
    await tester.pump();
    var slider = tester.widget<Slider>(
      find.byKey(const Key('media-volume-slider')),
    );
    slider.onChanged!(11);
    slider.onChangeEnd!(11);
    await tester.pump();
    slider = tester.widget(find.byKey(const Key('media-volume-slider')));
    expect(slider.value, 7);
    expect(find.textContaining('set failed'), findsOneWidget);

    bridge.setVolumeError = null;
    bridge.mediaVolume = const MediaVolume(current: 0, max: 0, fixed: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    slider = tester.widget(find.byKey(const Key('media-volume-slider')));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);
  });

  testWidgets(
    'background stops tone and confirmation enables only after play',
    (tester) async {
      final bridge = RegressionBridge()..blockedPlay = Completer<void>();
      await tester.pumpWidget(
        AudioShareApp(
          bridge: bridge,
          companionBridge: RegressionCompanion(),
          platform: TargetPlatform.android,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('测试与排障'));
      await tester.tap(find.text('测试与排障'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('test-tone')));
      final confirmations = tester
          .widgetList<TextButton>(find.byType(TextButton))
          .toList();
      expect(
        confirmations.takeLast(2).every((button) => button.onPressed == null),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      expect(
        tester
            .widgetList<TextButton>(find.byType(TextButton))
            .toList()
            .takeLast(2)
            .every((button) => button.onPressed == null),
        isTrue,
      );
      bridge.blockedPlay!.complete();
      await tester.pump();
      expect(
        tester
            .widgetList<TextButton>(find.byType(TextButton))
            .toList()
            .takeLast(2)
            .every((button) => button.onPressed != null),
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 2500));
      expect(
        bridge.toneStops,
        0,
        reason: 'the native timer owns natural release',
      );
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      expect(bridge.toneStops, 1, reason: 'manual stop remains native');
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(bridge.toneStops, 2, reason: 'background stop remains native');
    },
  );
}

extension<T> on List<T> {
  Iterable<T> takeLast(int count) => skip(length - count);
}
