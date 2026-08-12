import 'dart:async';

import 'package:audioshare/main.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBridge extends ExternalRouteBridge {
  List<BluetoothDeviceInfo> devices = const [];
  int refreshes = 0;
  bool started = false;
  Completer<BluetoothSinkStatus>? startCompleter;

  @override
  Future<List<BluetoothDeviceInfo>> listBluetoothDevices() async {
    refreshes++;
    return devices;
  }

  @override
  Future<BluetoothSinkStatus> startBluetoothSink({
    required String deviceId,
  }) async {
    final pending = startCompleter;
    if (pending != null) return pending.future;
    started = true;
    return const BluetoothSinkStatus(mode: 'connected', message: 'ok');
  }

  @override
  Future<BluetoothSinkStatus> stopBluetoothSink() async {
    started = false;
    return const BluetoothSinkStatus(mode: 'stopped', message: '已停止蓝牙接收。');
  }

  @override
  Future<BluetoothSinkStatus> getBluetoothSinkStatus() async =>
      BluetoothSinkStatus(mode: started ? 'connected' : 'stopped', message: '');

  @override
  Future<void> openBluetoothSettings() async {}
}

void main() {
  testWidgets('Android is a Bluetooth-only guide', (tester) async {
    await tester.pumpWidget(
      AudioShareApp(bridge: FakeBridge(), platform: TargetPlatform.android),
    );
    expect(find.text('在手机上选择媒体输出'), findsOneWidget);
    expect(find.text('打开系统蓝牙设置'), findsOneWidget);
    expect(find.textContaining('采集'), findsOneWidget);
  });

  testWidgets('Windows empty list explains pairing before refresh', (
    tester,
  ) async {
    await tester.pumpWidget(
      AudioShareApp(bridge: FakeBridge(), platform: TargetPlatform.windows),
    );
    await tester.pump();
    expect(find.textContaining('先在 Windows 添加设备完成普通蓝牙配对，再刷新'), findsOneWidget);
  });

  testWidgets('refresh enumerates and auto-selects a single device', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await tester.pumpWidget(
      AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
    );
    await tester.pump();
    bridge.devices = const [
      BluetoothDeviceInfo(id: 'phone', name: 'My Phone', isConnected: false),
    ];
    await tester.tap(find.text('刷新设备'));
    await tester.pump();
    expect(find.text('My Phone'), findsOneWidget);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('device-dropdown')),
    );
    expect(dropdown.initialValue, 'phone');
  });

  testWidgets('start succeeds and stop returns to idle state', (tester) async {
    final bridge = FakeBridge()
      ..devices = const [
        BluetoothDeviceInfo(id: 'phone', name: 'My Phone', isConnected: false),
      ];
    await tester.pumpWidget(
      AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(find.textContaining('HyperOS 3'), findsOneWidget);
    expect(find.byKey(const Key('stop-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop-button')));
    await tester.pump();
    expect(find.byKey(const Key('start-button')), findsOneWidget);
    expect(find.text('已停止蓝牙接收。'), findsOneWidget);
  });

  testWidgets('a pending native start can be cancelled without stale state', (
    tester,
  ) async {
    final pending = Completer<BluetoothSinkStatus>();
    final bridge = FakeBridge()
      ..devices = const [
        BluetoothDeviceInfo(id: 'phone', name: 'My Phone', isConnected: false),
      ]
      ..startCompleter = pending;
    await tester.pumpWidget(
      AudioShareApp(bridge: bridge, platform: TargetPlatform.windows),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(find.text('取消启动'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stop-button')));
    await tester.pump();
    expect(find.byKey(const Key('start-button')), findsOneWidget);

    pending.complete(
      const BluetoothSinkStatus(mode: 'connected', message: 'stale'),
    );
    await tester.pump();
    expect(find.byKey(const Key('start-button')), findsOneWidget);
    expect(find.textContaining('接收已启动'), findsNothing);
  });
}
