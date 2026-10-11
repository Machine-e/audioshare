// Render the real Flutter screens with simulated platform data, not hardware.
// Export PNGs: flutter test test/visual_preview_test.dart --dart-define=EXPORT_PREVIEWS=true
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioshare/main.dart';
import 'package:audioshare/platform/companion_bridge.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeBridge, FakeCompanion, status;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const export = bool.fromEnvironment('EXPORT_PREVIEWS');
  setUpAll(() async {
    if (!export) return;
    // Local Windows CJK font is used only for review artifacts, never bundled.
    final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
    final text = FontLoader('Geist Sans');
    if (await cjk.exists()) {
      text.addFont(
        cjk.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    text.addFont(rootBundle.load('assets/fonts/geist/Geist-Regular.ttf'));
    await text.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final scenario in [
    (
      'android-light',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'windows-opened',
      TargetPlatform.windows,
      const Size(1000, 760),
      Brightness.light,
    ),
    (
      'windows-dark',
      TargetPlatform.windows,
      const Size(1000, 760),
      Brightness.dark,
    ),
    (
      'windows-disconnected',
      TargetPlatform.windows,
      const Size(1000, 760),
      Brightness.light,
    ),
    (
      'windows-refresh',
      TargetPlatform.windows,
      const Size(1000, 760),
      Brightness.light,
    ),
    (
      'android-playing',
      TargetPlatform.android,
      const Size(412, 1250),
      Brightness.light,
    ),
    (
      'android-dark',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.dark,
    ),
    (
      'android-narrow',
      TargetPlatform.android,
      const Size(320, 720),
      Brightness.light,
    ),
    (
      'android-confirmed',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-fixed',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-error',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-opened',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-disconnected',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-permission',
      TargetPlatform.android,
      const Size(412, 900),
      Brightness.light,
    ),
    (
      'android-empty',
      TargetPlatform.android,
      const Size(412, 900),
      Brightness.light,
    ),
    (
      'android-scanning',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-local-connected',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
    (
      'android-motion',
      TargetPlatform.android,
      const Size(412, 1100),
      Brightness.light,
    ),
  ]) {
    testWidgets('render ${scenario.$1}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.$3;
      tester.platformDispatcher.platformBrightnessTestValue = scenario.$4;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final bridge = FakeBridge()
        ..preferred = 'phone'
        ..initial = NativeSinkState.opened
        ..mediaVolume = const MediaVolume(
          current: 0,
          max: 0,
          fixed: true,
          available: false,
          message: '当前蓝牙模式暂不支持独立音量与增益。',
        );
      if (scenario.$1 == 'android-fixed') {
        bridge.mediaVolume = const MediaVolume(
          current: 7,
          max: 15,
          fixed: true,
        );
      }
      if (scenario.$1 == 'android-error') {
        bridge.volumeReadError = Exception('无法读取媒体音量，请刷新重试');
      }
      final companion = FakeCompanion(
        snapshot: CompanionSnapshot(
          revision: 1,
          permission: scenario.$1 != 'android-permission',
          bluetoothEnabled: true,
          discovering: scenario.$1 == 'android-scanning',
          outputSwitcherSupported: true,
          devices: scenario.$1 == 'android-empty'
              ? const []
              : [
                  CompanionDevice(
                    id: 'pc1',
                    name: '开发电脑',
                    bonded: true,
                    a2dpStateKnown: true,
                    a2dpConnected:
                        scenario.$1 == 'android-local-connected' ||
                        scenario.$1 == 'android-opened' ||
                        scenario.$1 == 'android-playing',
                    a2dpPlaying: scenario.$1 == 'android-playing',
                    recent: true,
                    favorite: true,
                  ),
                  CompanionDevice(id: 'pc2', name: '客厅电脑', bonded: true),
                ],
          selectedDeviceId: scenario.$1 == 'android-empty' ? null : 'pc1',
          controlState: scenario.$1 == 'android-empty'
              ? CompanionControlState.idle
              : scenario.$1 == 'android-local-connected' ||
                    scenario.$1 == 'android-playing'
              ? CompanionControlState.unavailable
              : CompanionControlState.connected,
          receiverTarget: ReceiverTarget.thisPhone,
          receiverMode: switch (scenario.$1) {
            'android-opened' => 'opened',
            'android-disconnected' => 'disconnected',
            _ => 'waitingForRoute',
          },
        ),
      );
      addTearDown(companion.events.close);
      const capture = Key('preview-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: AudioShareApp(
            bridge: bridge,
            companionBridge: companion,
            platform: scenario.$2,
          ),
        ),
      );
      if (scenario.$1 == 'android-scanning') {
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
      } else {
        await tester.pumpAndSettle();
      }
      if (scenario.$1 == 'android-motion') {
        companion.events.add(
          CompanionSnapshot(
            revision: 2,
            permission: true,
            bluetoothEnabled: true,
            devices: companion.current.devices,
            selectedDeviceId: 'pc2',
            controlState: CompanionControlState.connecting,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (scenario.$1 == 'android-confirmed') {
        await tester.ensureVisible(find.text('测试与排障'));
        await tester.tap(find.text('测试与排障'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('test-tone')));
        await tester.tap(find.byKey(const Key('test-tone')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.ensureVisible(find.text('在电脑上听到了'));
        await tester.tap(find.text('在电脑上听到了'));
        await tester.pumpAndSettle();
        expect(find.text('已人工确认听到测试音。'), findsOneWidget);
      }
      if (scenario.$2 == TargetPlatform.windows) {
        await tester.tap(find.byKey(const Key('start-button')));
        await tester.pumpAndSettle();
        if (scenario.$1 == 'windows-disconnected') {
          bridge.waiters.first.complete(status(NativeSinkState.disconnected));
          await tester.pumpAndSettle();
          expect(find.text('手动重试'), findsOneWidget);
        } else {
          expect(find.text('手机媒体路由已连接'), findsOneWidget);
        }
        if (scenario.$1 == 'windows-refresh') {
          await tester.tap(find.byKey(const Key('refresh-status-service')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
      expect(tester.takeException(), isNull);
      if (export) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/ui-previews/${scenario.$1}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        if (scenario.$1 == 'android-motion' ||
            scenario.$1 == 'windows-refresh') {
          for (var frame = 0; frame < 12; frame++) {
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/ui-previews/${scenario.$1}-$frame.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
            await tester.pump(const Duration(milliseconds: 60));
          }
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
