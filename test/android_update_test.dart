import 'package:audioshare/android_screen.dart';
import 'package:audioshare/app_style.dart';
import 'package:audioshare/platform/android_update_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeBridge, FakeCompanion;

void main() {
  testWidgets(
    'missing APK is a release status; network failure stays readable',
    (tester) async {
      const channel = MethodChannel('com.machinee.audioshare/update');
      var fail = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (fail) {
              throw PlatformException(
                code: 'update_check_failed',
                message: '更新服务暂时限制了请求，请稍后重试',
                details: 'IllegalStateException',
              );
            }
            return {
              'available': false,
              'currentVersion': '0.2.2',
              'latestVersion': '',
              'downloadUrl': '',
              'message': '发布页暂未提供适合此手机的 Android 安装包',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final companion = FakeCompanion();
      addTearDown(companion.events.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: audioShareTheme(Brightness.light),
          home: Scaffold(
            body: AndroidScreen(
              routeBridge: FakeBridge(),
              companionBridge: companion,
              updateBridge: AndroidUpdateBridge(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.text('发布页暂未提供适合此手机的 Android 安装包'), findsOneWidget);
      expect(find.byKey(const Key('install-update')), findsNothing);
      expect(find.text('当前已是最新版本'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('check-update')));
      fail = true;
      await tester.tap(find.byKey(const Key('check-update')));
      await tester.pumpAndSettle();
      expect(find.text('更新服务暂时限制了请求，请稍后重试'), findsOneWidget);
      expect(find.textContaining('IllegalStateException'), findsNothing);
      expect(find.textContaining('PlatformException'), findsNothing);
      fail = false;
      await tester.tap(find.byKey(const Key('check-update')));
      await tester.pumpAndSettle();
      expect(find.text('发布页暂未提供适合此手机的 Android 安装包'), findsOneWidget);
      expect(find.text('更新服务暂时限制了请求，请稍后重试'), findsNothing);
    },
  );
}
