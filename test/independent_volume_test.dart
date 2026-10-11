import 'package:audioshare/main.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeCompanion;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy system volume response cannot enable a transmission slider', () {
    final volume = MediaVolume.fromMap({
      'current': 7,
      'max': 15,
      'fixed': false,
    });
    expect(volume.available, isFalse);
  });

  testWidgets('A2DP does not offer a slider that changes system volume', (
    tester,
  ) async {
    const channel = MethodChannel('com.machinee.audioshare/external_route');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getMediaVolume') {
            return {
              'available': false,
              'current': 0,
              'max': 0,
              'fixed': true,
              'message': '当前蓝牙模式暂不支持独立音量与增益。',
            };
          }
          throw PlatformException(code: 'independent_volume_unavailable');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final companion = FakeCompanion();
    addTearDown(companion.events.close);
    await tester.pumpWidget(
      AudioShareApp(
        platform: TargetPlatform.android,
        bridge: ExternalRouteBridge(),
        companionBridge: companion,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-volume-slider')), findsNothing);
    expect(find.text('当前蓝牙模式暂不支持独立音量与增益。'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('refresh-volume')));
    await tester.tap(find.byKey(const Key('refresh-volume')));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'getMediaVolume').length, 2);
    expect(calls, isNot(contains('setMediaVolume')));
  });
}
