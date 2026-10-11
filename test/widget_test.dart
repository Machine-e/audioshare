import 'dart:async';
import 'package:audioshare/main.dart';
import 'package:audioshare/platform/companion_bridge.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BluetoothSinkStatus status(NativeSinkState state) =>
    BluetoothSinkStatus(state: state, message: state.name);

class FakeBridge extends ExternalRouteBridge {
  List<BluetoothDeviceInfo> devices = const [
    BluetoothDeviceInfo(id: 'phone', name: 'My Phone'),
  ];
  final waiters = <Completer<BluetoothSinkStatus>>[];
  Completer<BluetoothSinkStatus>? pendingStart;
  Completer<List<BluetoothDeviceInfo>>? pendingRefresh;
  int waits = 0, stops = 0, settings = 0;
  int toneStarts = 0, toneStops = 0;
  NativeSinkState initial = NativeSinkState.waitingForRoute;
  String? preferred;
  final writes = <String>[];
  Completer<String?>? pendingPreference;
  MediaVolume mediaVolume = const MediaVolume(
    current: 7,
    max: 15,
    fixed: false,
  );
  Object? volumeReadError;
  final setVolumes = <int>[];
  bool statusServiceAvailable = true;
  int statusReads = 0;
  int deviceReads = 0;
  @override
  Future<({bool available, String message})> getStatusServiceInfo() async {
    statusReads++;
    return (
      available: statusServiceAvailable,
      message: statusServiceAvailable ? '状态服务已就绪' : '蓝牙状态服务不可用',
    );
  }

  @override
  Future<String?> readPreferredDevice() =>
      pendingPreference?.future ?? Future.value(preferred);
  @override
  Future<void> writePreferredDevice(String deviceId) async {
    writes.add(deviceId);
    preferred = deviceId;
  }

  @override
  Future<MediaVolume> getMediaVolume() async {
    if (volumeReadError != null) throw volumeReadError!;
    return mediaVolume;
  }

  @override
  Future<MediaVolume> setMediaVolume(int value) async {
    setVolumes.add(value);
    return MediaVolume(current: value, max: mediaVolume.max, fixed: false);
  }

  @override
  Future<void> playTestTone() async => toneStarts++;
  @override
  Future<void> stopTestTone() async => toneStops++;
  @override
  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() {
    deviceReads++;
    return pendingRefresh?.future ?? Future.value(devices);
  }

  @override
  Future<BluetoothSinkStatus> startBluetoothSink({required String deviceId}) =>
      pendingStart?.future ?? Future.value(status(initial));
  @override
  Future<BluetoothSinkStatus> stopBluetoothSink() async {
    stops++;
    return status(NativeSinkState.stopped);
  }

  @override
  Future<BluetoothSinkStatus> waitBluetoothSinkStatusChange() {
    waits++;
    final c = Completer<BluetoothSinkStatus>();
    waiters.add(c);
    return c.future;
  }

  @override
  Future<void> openBluetoothSettings() async {
    settings++;
  }
}

class FakeCompanion extends CompanionBridge {
  FakeCompanion({CompanionSnapshot? snapshot})
    : current =
          snapshot ??
          const CompanionSnapshot(permission: true, bluetoothEnabled: true);
  CompanionSnapshot current;
  final events = StreamController<CompanionSnapshot>.broadcast();
  @override
  Stream<CompanionSnapshot> get snapshots => events.stream;
  @override
  Future<CompanionSnapshot> getSnapshot() async => current;
  @override
  Future<CompanionSnapshot> requestAccess() async => current;
  @override
  Future<CompanionSnapshot> startDiscovery() async => current;
  @override
  Future<CompanionSnapshot> stopDiscovery() async => current;
}

Future<void> windows(WidgetTester tester, FakeBridge bridge) async {
  await tester.pumpWidget(
    AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
  );
  await tester.pump();
  if (bridge.devices.isNotEmpty) {
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('device-dropdown')),
    );
    dropdown.onChanged!(bridge.devices.first.id);
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'Windows refresh queries again, updates data and visibly animates',
    (tester) async {
      final bridge = FakeBridge();
      await windows(tester, bridge);
      await tester.pumpAndSettle();
      final oldStatusReads = bridge.statusReads;
      bridge.statusServiceAvailable = false;
      await tester.ensureVisible(
        find.byKey(const Key('refresh-status-service')),
      );
      await tester.tap(find.byKey(const Key('refresh-status-service')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(bridge.statusReads, oldStatusReads + 1);
      expect(find.text('不可用：蓝牙状态服务不可用'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      final oldDeviceReads = bridge.deviceReads;
      bridge.devices = const [
        BluetoothDeviceInfo(id: 'new', name: 'New phone'),
      ];
      await tester.ensureVisible(find.text('刷新设备'));
      await tester.tap(find.text('刷新设备'));
      await tester.pumpAndSettle();
      expect(bridge.deviceReads, oldDeviceReads + 1);
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('device-dropdown')),
      );
      expect(dropdown.items!.single.value, 'new');
      expect(bridge.stops, 0);
    },
  );

  testWidgets('status service failure does not stop audio reception', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..statusServiceAvailable = false
      ..initial = NativeSinkState.opened;
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pumpAndSettle();
    expect(find.text('手机媒体路由已连接'), findsOneWidget);
    expect(find.text('不可用：蓝牙状态服务不可用'), findsOneWidget);
    expect(bridge.stops, 0);
  });

  test('bridge accepts only the five native states', () {
    expect(
      BluetoothSinkStatus.fromMap({'mode': 'opened'}).state,
      NativeSinkState.opened,
    );
    expect(
      BluetoothSinkStatus.fromMap({'mode': 'connected'}).state,
      NativeSinkState.error,
    );
  });

  testWidgets('waiting to opened to disconnected continuously waits', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(find.text('等待手机选择此电脑'), findsOneWidget);
    expect(bridge.waits, 1);
    bridge.waiters[0].complete(status(NativeSinkState.opened));
    await tester.pump();
    expect(find.text('手机媒体路由已连接'), findsOneWidget);
    expect(bridge.waits, 2);
    bridge.waiters[1].complete(status(NativeSinkState.disconnected));
    await tester.pump();
    expect(find.text('连接已断开'), findsOneWidget);
  });

  testWidgets('waiting can be actively stopped', (tester) async {
    final bridge = FakeBridge();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop-button')));
    await tester.pump();
    expect(bridge.stops, 1);
    expect(find.text('尚未启动接收'), findsOneWidget);
  });

  testWidgets('late start is ignored after cancellation', (tester) async {
    final bridge = FakeBridge()
      ..pendingStart = Completer<BluetoothSinkStatus>();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop-button')));
    await tester.pump();
    bridge.pendingStart!.complete(status(NativeSinkState.opened));
    await tester.pump();
    expect(find.text('尚未启动接收'), findsOneWidget);
  });

  testWidgets('disconnect invalidates concurrent refresh', (tester) async {
    final bridge = FakeBridge();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    bridge.pendingRefresh = Completer<List<BluetoothDeviceInfo>>();
    await tester.tap(find.text('刷新设备'));
    await tester.pump();
    bridge.waiters.first.complete(status(NativeSinkState.disconnected));
    await tester.pump();
    bridge.pendingRefresh!.complete(const [
      BluetoothDeviceInfo(id: 'x', name: 'stale'),
    ]);
    await tester.pump();
    expect(find.text('stale'), findsNothing);
    expect(find.text('连接已断开'), findsOneWidget);
  });

  testWidgets('refresh failure cannot hide stop for an active sink', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    bridge.pendingRefresh = Completer<List<BluetoothDeviceInfo>>();
    await tester.tap(find.text('刷新设备'));
    await tester.pump();
    bridge.pendingRefresh!.completeError(Exception('enumeration failed'));
    await tester.pump();
    expect(find.byKey(const Key('stop-button')), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsOneWidget);
  });

  testWidgets('narrow large text remains scrollable without exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bridge = FakeBridge()
      ..devices = const [
        BluetoothDeviceInfo(
          id: 'p',
          name: 'A very very very long paired Bluetooth phone device name',
        ),
      ];
    await tester.pumpWidget(
      AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
    );
    await tester.pump();
    final context = tester.element(find.byType(Scaffold));
    expect(MediaQuery.textScalerOf(context).scale(10), 20);
    await tester.scrollUntilVisible(find.byKey(const Key('start-button')), 100);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('start-button')), findsOneWidget);
  });

  testWidgets('system dark brightness selects dark scheme', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await windows(tester, FakeBridge());
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.brightness,
      Brightness.dark,
    );
  });

  testWidgets('live status semantics updates', (tester) async {
    final bridge = FakeBridge();
    final semantics = tester.ensureSemantics();
    await windows(tester, bridge);
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(const Key('status-semantics'))).label,
      contains('等待手机选择此电脑'),
    );
    bridge.waiters.first.complete(status(NativeSinkState.opened));
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(const Key('status-semantics'))).label,
      contains('手机媒体路由已连接'),
    );
    semantics.dispose();
  });

  testWidgets('Android has four honest steps, volume and settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      AudioShareApp(
        bridge: FakeBridge(),
        companionBridge: FakeCompanion(),
        platform: TargetPlatform.android,
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('连接指南'));
    await tester.tap(find.text('连接指南'));
    await tester.pumpAndSettle();
    expect(find.text('1. 与 Windows 电脑完成蓝牙配对。'), findsOneWidget);
    expect(find.text('2. 在电脑端选择手机并开启接收。'), findsOneWidget);
    expect(find.text('3. 在手机媒体输出中选择这台电脑。'), findsOneWidget);
    await tester.ensureVisible(find.text('测试与排障'));
    await tester.tap(find.text('测试与排障'));
    await tester.pumpAndSettle();
    expect(find.text('4. 播放测试音并由你确认是否听到。'), findsOneWidget);
    expect(find.byKey(const Key('media-volume-slider')), findsOneWidget);
    expect(find.byKey(const Key('android-settings')), findsOneWidget);
    expect(find.byIcon(Icons.settings_bluetooth), findsOneWidget);
  });

  testWidgets(
    'Android slider drafts then commits and fixed volume disables it',
    (tester) async {
      final bridge = FakeBridge();
      await tester.pumpWidget(
        AudioShareApp(
          bridge: bridge,
          companionBridge: FakeCompanion(),
          platform: TargetPlatform.android,
        ),
      );
      await tester.pump();
      var slider = tester.widget<Slider>(
        find.byKey(const Key('media-volume-slider')),
      );
      slider.onChanged!(11);
      await tester.pump();
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('media-volume-slider')))
            .value,
        11,
      );
      slider = tester.widget(find.byKey(const Key('media-volume-slider')));
      slider.onChangeEnd!(11);
      await tester.pump();
      expect(bridge.setVolumes, [11]);

      bridge.mediaVolume = const MediaVolume(current: 7, max: 15, fixed: true);
      await tester.ensureVisible(find.byKey(const Key('refresh-volume')));
      await tester.tap(find.byKey(const Key('refresh-volume')));
      await tester.pump();
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('media-volume-slider')))
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets(
    'volume read failure ends loading and tone resets automatically',
    (tester) async {
      final bridge = FakeBridge()..volumeReadError = Exception('read failed');
      await tester.pumpWidget(
        AudioShareApp(
          bridge: bridge,
          companionBridge: FakeCompanion(),
          platform: TargetPlatform.android,
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('read failed'), findsOneWidget);

      bridge.volumeReadError = null;
      await tester.ensureVisible(find.text('测试与排障'));
      await tester.tap(find.text('测试与排障'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('test-tone')));
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      expect(find.text('停止测试音'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2500));
      expect(find.text('播放 2.5 秒测试音'), findsOneWidget);
      // Native duration owns automatic release; Dart only updates the label.
      expect(bridge.toneStops, 0);
      await tester.tap(find.byKey(const Key('test-tone')));
      await tester.pump();
      expect(bridge.toneStarts, 2);
    },
  );

  test(
    'device enumeration does not wait for a hanging preference read',
    () async {
      final bridge = FakeBridge()..pendingPreference = Completer<String?>();
      final controller = AudioShareController(bridge: bridge, isWindows: true);
      unawaited(controller.initialize());
      await Future<void>.delayed(Duration.zero);
      expect(controller.devices, bridge.devices);
      controller.dispose();
    },
  );

  test(
    'selection wins over late cache and missing device stays unselected',
    () async {
      final bridge = FakeBridge()..pendingPreference = Completer<String?>();
      final controller = AudioShareController(bridge: bridge, isWindows: true);
      final init = controller.initialize();
      controller.selectDevice('phone');
      bridge.pendingPreference!.complete('old');
      await init;
      expect(controller.preferredDeviceId, 'phone');
      expect(controller.selectedDeviceId, 'phone');
      bridge.devices = const [BluetoothDeviceInfo(id: 'other', name: 'Other')];
      await controller.refreshDevices();
      expect(controller.preferredDeviceId, 'phone');
      expect(controller.selectedDeviceId, isNull);
      controller.dispose();
    },
  );
}
