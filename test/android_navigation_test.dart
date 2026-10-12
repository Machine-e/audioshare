import 'package:audioshare/app_style.dart';
import 'package:audioshare/platform/companion_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_flow_test.dart' show FakeCompanionBridge, pumpAndroid;
import 'widget_test.dart' show FakeBridge;

CompanionSnapshot observation(
  int revision, {
  bool connected = false,
  bool known = true,
  String message = '',
}) => CompanionSnapshot(
  revision: revision,
  permission: true,
  bluetoothEnabled: true,
  selectedDeviceId: 'pc',
  outputSwitcherSupported: true,
  controlState: CompanionControlState.unavailable,
  message: message,
  devices: [
    CompanionDevice(
      id: 'pc',
      name: '我的电脑',
      bonded: true,
      a2dpConnected: connected,
      a2dpStateKnown: known,
    ),
  ],
);

void main() {
  testWidgets('computer message has its own padded block below media actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpAndroid(
      tester,
      FakeCompanionBridge(
        observation(1, connected: true, message: '控制状态已连接，正在等待电脑报告当前接收状态。'),
      ),
    );
    await tester.pumpAndSettle();
    final message = find.text('电脑消息：控制状态已连接，正在等待电脑报告当前接收状态。');
    await tester.ensureVisible(message);
    await tester.pumpAndSettle();
    final output = tester.getRect(find.byKey(const Key('output-switcher')));
    final note = tester.getRect(message);
    expect(note.top - output.bottom, greaterThanOrEqualTo(32));
    expect(note.right, lessThanOrEqualTo(300));
    expect(find.byKey(const Key('computer-message')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tabs retain connection subscription and separate playback from settings',
    (tester) async {
      final companion = FakeCompanionBridge(observation(1, connected: true));
      final route = FakeBridge();
      await pumpAndroid(tester, companion, route: route);
      await tester.pumpAndSettle();
      ConnectionIndicatorState indicator() => tester
          .widget<ConnectionStatusLabel>(
            find.byKey(const Key('primary-media-status')),
          )
          .state;
      expect(indicator(), ConnectionIndicatorState.connected);
      expect(
        tester
            .widget<ConnectionStatusLabel>(
              find.byKey(const Key('receiver-status')),
            )
            .state,
        ConnectionIndicatorState.unknown,
      );
      expect(find.byKey(const Key('output-switcher')), findsOneWidget);
      expect(find.text('应用更新'), findsNothing);
      for (final page in ['nav-devices', 'nav-settings']) {
        await tester.tap(find.byKey(Key(page)));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('output-switcher')), findsNothing);
      }
      expect(find.text('应用更新'), findsOneWidget);
      // A disconnect while on another page must be visible on return.
      companion.controller.add(observation(2));
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-playback')));
      await tester.pumpAndSettle();
      expect(indicator(), ConnectionIndicatorState.disconnected);
      expect(find.text('蓝牙媒体已断开'), findsOneWidget);
      companion.controller.add(observation(3, known: false));
      await tester.pumpAndSettle();
      expect(indicator(), ConnectionIndicatorState.unknown);
      expect(route.stops, 0);
      expect(companion.disconnects, 0);
      expect(companion.selectedDevices, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('output-switcher')));
      await tester.tap(find.byKey(const Key('output-switcher')));
      expect(companion.outputSwitcherRequests, 1);
    },
  );

  testWidgets(
    'bottom navigation stays visible on narrow screens with large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpAndroid(tester, FakeCompanionBridge(observation(1)));
      await tester.pumpAndSettle();
      for (final page in ['nav-devices', 'nav-settings', 'nav-playback']) {
        await tester.tap(find.byKey(Key(page)));
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(const Key('android-navigation')),
        );
        expect(rect.bottom, lessThanOrEqualTo(640));
        expect(rect.top, greaterThan(0));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
