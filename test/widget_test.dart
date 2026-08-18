import 'dart:async';
import 'package:audioshare/main.dart';
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
  NativeSinkState initial = NativeSinkState.waitingForRoute;
  @override
  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() =>
      pendingRefresh?.future ?? Future.value(devices);
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

Future<void> windows(WidgetTester tester, FakeBridge bridge) async {
  await tester.pumpWidget(
    AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
  );
  await tester.pump();
}

void main() {
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

  testWidgets('Android has three steps and one settings entry', (tester) async {
    await tester.pumpWidget(
      AudioShareApp(bridge: FakeBridge(), platform: TargetPlatform.android),
    );
    expect(find.text('1. 与 Windows 电脑完成蓝牙配对。'), findsOneWidget);
    expect(find.text('2. 为这台电脑启用“媒体音频”。'), findsOneWidget);
    expect(find.text('3. 播放时在媒体输出中选择这台电脑。'), findsOneWidget);
    expect(find.byKey(const Key('android-settings')), findsOneWidget);
    expect(find.byIcon(Icons.settings_bluetooth), findsOneWidget);
  });
}
