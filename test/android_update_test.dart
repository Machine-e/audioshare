import 'dart:async';
import 'package:audioshare/android_screen.dart';
import 'package:audioshare/app_style.dart';
import 'package:audioshare/platform/android_update_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeBridge, FakeCompanion;

void main() {
  testWidgets(
    'download shows byte progress, survives resume and retries failures',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const channel = MethodChannel('com.machinee.audioshare/update');
      const events = MethodChannel('com.machinee.audioshare/update_progress');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pending = Completer<void>();
      String? requestId;
      var downloads = 0, cancellations = 0;
      messenger.setMockMethodCallHandler(events, (call) async {
        if (call.method == 'cancel') cancellations++;
        return null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'checkForUpdate') {
          return {
            'available': true,
            'currentVersion': '0.2.5',
            'latestVersion': '0.2.6',
            'downloadUrl':
                'https://github.com/Machine-e/audioshare/releases/download/v0.2.6/AudioShare-Android.apk',
          };
        }
        downloads++;
        requestId = (call.arguments as Map)['requestId'] as String;
        await pending.future;

        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(events, null);
      });
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
      await tester.ensureVisible(find.byKey(const Key('install-update')));
      await tester.tap(find.byKey(const Key('install-update')));
      await tester.pump();
      LinearProgressIndicator progress() =>
          tester.widget(find.byKey(const Key('update-download-progress')));
      Future<void> emit(
        int received,
        int total, {
        String? id,
        String stage = 'downloading',
      }) async {
        await messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'requestId': id ?? requestId,
            'received': received,
            'total': total,
            'stage': stage,
          }),
          (_) {},
        );
        await tester.pump();
      }

      expect(progress().value, isNull);
      await emit(1048576, 0);
      expect(find.text('已下载 1.0 MB'), findsOneWidget);
      await emit(2097152, 8388608);
      expect(progress().value, .25);
      expect(find.text('25%'), findsOneWidget);
      await emit(8000000, 8388608, id: 'stale-request');
      expect(progress().value, .25);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('install-update')))
            .onPressed,
        isNull,
      );
      expect(downloads, 1);
      await tester.runAsync(() async {
        pending.completeError(
          PlatformException(code: 'download_failed', message: '网络中断，请重试'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-download-progress')), findsNothing);
      expect(find.text('重新下载'), findsOneWidget);
      expect(cancellations, 1);
      pending = Completer<void>();
      await tester.ensureVisible(find.byKey(const Key('install-update')));
      await tester.tap(find.byKey(const Key('install-update')));
      await tester.pump();
      await emit(8388608, 8388608, stage: 'installing');
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('下载完成，正在打开安装器…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        pending.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(cancellations, 2);
      expect(downloads, 2);
      expect(find.byKey(const Key('update-download-progress')), findsNothing);
      expect(find.text('安装包已下载，请在系统安装器中确认更新。'), findsOneWidget);
    },
  );

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
