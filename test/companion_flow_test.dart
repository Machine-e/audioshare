import 'dart:async';

import 'package:audioshare/main.dart';
import 'package:audioshare/platform/companion_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeBridge;

class FakeCompanionBridge extends CompanionBridge {
  FakeCompanionBridge(this.current);

  CompanionSnapshot current;
  final controller = StreamController<CompanionSnapshot>.broadcast();
  Completer<CompanionSnapshot>? snapshotCompleter;
  Completer<CompanionSnapshot>? discoveryCompleter;
  final selectedDevices = <String>[];
  final favorites = <(String, bool)>[];
  int accessRequests = 0;
  int discoveryStarts = 0;
  int discoveryStops = 0;
  int disconnects = 0;
  int outputSwitcherRequests = 0;
  int tileRequests = 0;
  int statusRetries = 0;
  final pinnedDevices = <String>[];
  bool outputSwitcherResult = true;
  bool pinResult = true;
  bool tileResult = true;

  @override
  Stream<CompanionSnapshot> get snapshots => controller.stream;

  @override
  Future<CompanionSnapshot> getSnapshot() =>
      snapshotCompleter?.future ?? Future.value(current);

  @override
  Future<CompanionSnapshot> retryStatus() async {
    statusRetries++;
    return current;
  }

  @override
  Future<CompanionSnapshot> requestAccess() async {
    accessRequests++;
    return current;
  }

  @override
  Future<CompanionSnapshot> startDiscovery() {
    discoveryStarts++;
    return discoveryCompleter?.future ?? Future.value(current);
  }

  @override
  Future<CompanionSnapshot> stopDiscovery() async {
    discoveryStops++;
    return current;
  }

  @override
  Future<CompanionSnapshot> selectDevice(String deviceId) async {
    selectedDevices.add(deviceId);
    return current;
  }

  @override
  Future<CompanionSnapshot> setFavorite(String deviceId, bool favorite) async {
    favorites.add((deviceId, favorite));
    return current;
  }

  @override
  Future<CompanionSnapshot> disconnectControl() async {
    disconnects++;
    return current;
  }

  @override
  Future<bool> showOutputSwitcher() async {
    outputSwitcherRequests++;
    return outputSwitcherResult;
  }

  @override
  Future<bool> pinShortcut(String deviceId) async {
    pinnedDevices.add(deviceId);
    return pinResult;
  }

  @override
  Future<bool> addQuickTile() async {
    tileRequests++;
    return tileResult;
  }
}

const devices = [
  CompanionDevice(id: 'alpha', name: 'Alpha PC'),
  CompanionDevice(id: 'beta', name: 'Beta PC', bonded: true),
];

Future<void> pumpAndroid(
  WidgetTester tester,
  FakeCompanionBridge companion, {
  FakeBridge? route,
}) async {
  addTearDown(companion.controller.close);
  await tester.pumpWidget(
    AudioShareApp(
      bridge: route ?? FakeBridge(),
      companionBridge: companion,
      platform: TargetPlatform.android,
    ),
  );
  await tester.pump();
}

void main() {
  const connectedPC = CompanionDevice(
    id: 'pc',
    name: 'PC',
    bonded: true,
    a2dpConnected: true,
    a2dpStateKnown: true,
  );
  test('invalidated observation cannot keep stale connected evidence', () {
    final parsed = CompanionDevice.fromMap({
      'id': 'pc',
      'a2dpConnected': true,
      'a2dpPlaying': true,
      'a2dpStateKnown': true,
    });
    expect(parsed.a2dpStateKnown, isTrue);
    expect(parsed.a2dpPlaying, isTrue);
    final cleared = CompanionSnapshot(devices: [parsed]).withoutReceiver();
    expect(cleared.devices.single.a2dpStateKnown, isFalse);
    expect(cleared.devices.single.a2dpConnected, isFalse);
    expect(cleared.devices.single.a2dpPlaying, isFalse);
  });

  testWidgets('local A2DP survives status failure; retry is independent', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        devices: [connectedPC],
        selectedDeviceId: 'pc',
        controlState: CompanionControlState.unavailable,
      ),
    );
    await pumpAndroid(tester, companion);
    expect(find.text('本机蓝牙媒体：已连接到此电脑'), findsOneWidget);
    expect(find.text('电脑不可用'), findsNothing);
    expect(find.text('连接已打开'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('retry-status')));
    await tester.pumpAndSettle();
    tester
        .widget<TextButton>(find.byKey(const Key('retry-status')))
        .onPressed!();
    await tester.pump();
    expect(companion.statusRetries, 1);
    expect(companion.disconnects, 0);
  });

  testWidgets('receiver error and disconnect are not masked by local A2DP', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(permission: true, bluetoothEnabled: true),
    );
    await pumpAndroid(tester, companion);
    var revision = 1;
    for (final entry in [('disconnected', '连接已断开'), ('error', '电脑接收出错')]) {
      companion.controller.add(
        CompanionSnapshot(
          revision: revision++,
          permission: true,
          bluetoothEnabled: true,
          devices: const [connectedPC],
          selectedDeviceId: 'pc',
          controlState: CompanionControlState.connected,
          receiverMode: entry.$1,
          receiverTarget: ReceiverTarget.thisPhone,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text('本机蓝牙媒体：已连接到此电脑'), findsOneWidget);
      expect(find.text('连接已打开'), findsNothing);
    }
  });

  testWidgets('playing event updates primary status without snapshot polling', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        devices: [CompanionDevice(id: 'pc', name: 'PC', bonded: true)],
        selectedDeviceId: 'pc',
      ),
    );
    await pumpAndroid(tester, companion);
    companion.controller.add(
      const CompanionSnapshot(
        revision: 1,
        permission: true,
        bluetoothEnabled: true,
        devices: [
          CompanionDevice(
            id: 'pc',
            name: 'PC',
            bonded: true,
            a2dpPlaying: true,
            a2dpStateKnown: true,
          ),
        ],
        selectedDeviceId: 'pc',
      ),
    );
    await tester.pump();
    expect(find.text('正在通过电脑播放'), findsOneWidget);
    expect(companion.statusRetries, 0);
    companion.controller.add(
      const CompanionSnapshot(
        revision: 2,
        permission: true,
        bluetoothEnabled: true,
        devices: [
          CompanionDevice(
            id: 'pc',
            name: 'PC',
            bonded: true,
            a2dpStateKnown: true,
            a2dpConnected: true,
          ),
        ],
        selectedDeviceId: 'pc',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在通过电脑播放'), findsNothing);
    expect(find.text('蓝牙媒体已连接'), findsOneWidget);
    companion.controller.add(
      const CompanionSnapshot(
        revision: 3,
        permission: true,
        bluetoothEnabled: true,
        devices: [
          CompanionDevice(
            id: 'pc',
            name: 'PC',
            bonded: true,
            a2dpStateKnown: true,
          ),
        ],
        selectedDeviceId: 'pc',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('蓝牙媒体已连接'), findsNothing);
    expect(find.text('本机蓝牙媒体：未连接此电脑'), findsOneWidget);
  });

  testWidgets(
    'this-phone opened evidence never shows a contradictory local false',
    (tester) async {
      final companion = FakeCompanionBridge(
        const CompanionSnapshot(
          permission: true,
          bluetoothEnabled: true,
          devices: [
            CompanionDevice(
              id: 'pc',
              name: 'PC',
              bonded: true,
              a2dpStateKnown: true,
            ),
          ],
          selectedDeviceId: 'pc',
          controlState: CompanionControlState.connected,
          receiverMode: 'opened',
          receiverTarget: ReceiverTarget.thisPhone,
        ),
      );
      await pumpAndroid(tester, companion);
      expect(find.text('蓝牙媒体已连接'), findsOneWidget);
      expect(find.text('正在通过电脑播放'), findsNothing);
      expect(find.text('本机蓝牙媒体：未连接此电脑'), findsNothing);
    },
  );

  testWidgets(
    'unknown target opened does not claim this phone; unknown profile is not disconnected',
    (tester) async {
      final companion = FakeCompanionBridge(
        const CompanionSnapshot(
          permission: true,
          bluetoothEnabled: true,
          devices: [CompanionDevice(id: 'pc', name: 'PC', bonded: true)],
          selectedDeviceId: 'pc',
          controlState: CompanionControlState.connected,
          receiverMode: 'opened',
        ),
      );
      await pumpAndroid(tester, companion);
      expect(find.text('电脑媒体路由已打开'), findsOneWidget);
      expect(find.text('连接已打开'), findsNothing);
      expect(find.text('本机蓝牙媒体状态：正在确认'), findsOneWidget);
      expect(find.text('本机蓝牙媒体：未连接此电脑'), findsNothing);
    },
  );

  testWidgets('selection animates then settles and respects reduced motion', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        devices: devices,
      ),
    );
    await pumpAndroid(tester, companion);
    await tester.pumpAndSettle();
    companion.controller.add(
      const CompanionSnapshot(
        revision: 1,
        permission: true,
        bluetoothEnabled: true,
        devices: devices,
        selectedDeviceId: 'beta',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpAndSettle();
    final card = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const Key('device-beta')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(card.duration, Duration.zero);
  });

  testWidgets(
    'permission, Bluetooth-off, and empty states expose their actions',
    (tester) async {
      final companion = FakeCompanionBridge(const CompanionSnapshot());
      await pumpAndroid(tester, companion);
      expect(find.byKey(const Key('request-access')), findsOneWidget);
      await tester.tap(find.byKey(const Key('request-access')));
      await tester.pump();
      expect(companion.accessRequests, 1);

      companion.controller.add(
        const CompanionSnapshot(revision: 1, permission: true),
      );
      await tester.pump();
      expect(find.text('蓝牙已关闭，请先开启蓝牙。'), findsOneWidget);
      expect(find.byKey(const Key('enable-bluetooth')), findsOneWidget);

      companion.controller.add(
        const CompanionSnapshot(
          revision: 2,
          permission: true,
          bluetoothEnabled: true,
        ),
      );
      await tester.pump();
      expect(find.text('没有找到电脑'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discover-empty')));
      await tester.pump();
      expect(companion.discoveryStarts, 1);
    },
  );

  testWidgets('device cards select exact id without opening system settings', (
    tester,
  ) async {
    final route = FakeBridge();
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        devices: devices,
      ),
    );
    await pumpAndroid(tester, companion, route: route);
    expect(find.text('Alpha PC'), findsOneWidget);
    expect(find.text('Beta PC'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-alpha')));
    await tester.pump();
    expect(companion.selectedDevices, ['alpha']);
    expect(route.settings, 0);

    await tester.tap(find.byKey(const Key('discover')));
    await tester.pump();
    expect(companion.discoveryStarts, 1);
  });

  testWidgets(
    'newer idle event clears opened label and stale event cannot revive it',
    (tester) async {
      final companion = FakeCompanionBridge(
        const CompanionSnapshot(permission: true, bluetoothEnabled: true),
      );
      await pumpAndroid(tester, companion);
      companion.controller.add(
        const CompanionSnapshot(
          revision: 10,
          permission: true,
          bluetoothEnabled: true,
          controlState: CompanionControlState.connected,
          receiverMode: 'opened',
          receiverTarget: ReceiverTarget.thisPhone,
        ),
      );
      await tester.pump();
      expect(find.text('连接已打开'), findsOneWidget);

      companion.controller.add(
        const CompanionSnapshot(
          revision: 11,
          permission: true,
          bluetoothEnabled: true,
        ),
      );
      await tester.pump();
      expect(find.text('连接已打开'), findsNothing);
      companion.controller.add(
        const CompanionSnapshot(
          revision: 10,
          permission: true,
          bluetoothEnabled: true,
          controlState: CompanionControlState.connected,
          receiverMode: 'opened',
          receiverTarget: ReceiverTarget.thisPhone,
        ),
      );
      await tester.pump();
      expect(find.text('连接已打开'), findsNothing);
    },
  );

  testWidgets('other and unknown receiver targets are never shown as ready', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        controlState: CompanionControlState.connected,
        receiverMode: 'waitingForRoute',
        receiverTarget: ReceiverTarget.otherPhone,
      ),
    );
    await pumpAndroid(tester, companion);
    expect(find.text('电脑已准备好'), findsNothing);
    expect(find.text('电脑已选择其他手机'), findsOneWidget);
    companion.controller.add(
      const CompanionSnapshot(
        revision: 1,
        permission: true,
        bluetoothEnabled: true,
        controlState: CompanionControlState.connected,
        receiverMode: 'waitingForRoute',
        receiverTarget: ReceiverTarget.unknown,
      ),
    );
    await tester.pump();
    expect(find.text('电脑已准备好'), findsNothing);
    expect(find.text('无法确认接收目标'), findsOneWidget);
  });

  testWidgets(
    'shortcut actions report success and false results provide fallback',
    (tester) async {
      final companion = FakeCompanionBridge(
        const CompanionSnapshot(
          permission: true,
          bluetoothEnabled: true,
          devices: devices,
          selectedDeviceId: 'beta',
        ),
      );
      await pumpAndroid(tester, companion);
      await tester.ensureVisible(find.byKey(const Key('pin-shortcut')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pin-shortcut')));
      await tester.pump();
      expect(companion.pinnedDevices, ['beta']);
      expect(find.textContaining('操作失败'), findsNothing);
      await tester.tap(find.byKey(const Key('add-tile')));
      await tester.pump();
      expect(companion.tileRequests, 1);
      expect(find.textContaining('操作失败'), findsNothing);

      companion.tileResult = false;
      await tester.tap(find.byKey(const Key('add-tile')));
      await tester.pump();
      expect(find.textContaining('手动添加'), findsOneWidget);
    },
  );

  testWidgets('unsupported output switcher result gives feedback', (
    tester,
  ) async {
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(
        permission: true,
        bluetoothEnabled: true,
        outputSwitcherSupported: true,
      ),
    )..outputSwitcherResult = false;
    await pumpAndroid(tester, companion);
    await tester.ensureVisible(find.byKey(const Key('output-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('output-switcher')));
    await tester.pump();
    expect(companion.outputSwitcherRequests, 1);
    expect(find.textContaining('操作失败'), findsOneWidget);
  });

  testWidgets(
    'two devices fit narrow large-text layout and volume is reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final companion = FakeCompanionBridge(
        const CompanionSnapshot(
          permission: true,
          bluetoothEnabled: true,
          devices: devices,
        ),
      );
      await pumpAndroid(tester, companion);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('传输音量'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-volume-slider')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('physical slider drag updates percent and commits only on end', (
    tester,
  ) async {
    final route = FakeBridge();
    final companion = FakeCompanionBridge(
      const CompanionSnapshot(permission: true, bluetoothEnabled: true),
    );
    await pumpAndroid(tester, companion, route: route);
    final slider = find.byKey(const Key('media-volume-slider'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    expect(find.text('47%'), findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(route.setVolumes, isEmpty);
    expect(find.text('47%'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(route.setVolumes, hasLength(1));
  });
}
