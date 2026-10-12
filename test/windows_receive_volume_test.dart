import 'dart:async';
import 'package:audioshare/app_style.dart';
import 'package:audioshare/platform/external_route_bridge.dart';
import 'package:audioshare/windows_receive_volume.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ReceiveBridge extends ExternalRouteBridge {
  final writes = <int>[];
  Completer<MediaVolume>? pending;
  bool fail = false;
  @override
  Future<MediaVolume> getReceiveVolume() async =>
      const MediaVolume(current: 100, max: 100, fixed: false);
  @override
  Future<MediaVolume> setReceiveVolume(int value) async {
    writes.add(value);
    if (fail) throw StateError('gone');
    return pending != null
        ? pending!.future
        : MediaVolume(current: value, max: 100, fixed: false);
  }
}

void main() {
  testWidgets(
    'receive volume flushes release immediately and disables after a failed write',
    (tester) async {
      final bridge = ReceiveBridge();
      await tester.pumpWidget(
        MaterialApp(
          theme: audioShareTheme(Brightness.light),
          home: Scaffold(
            body: WindowsReceiveVolume(bridge: bridge, connected: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Slider slider() =>
          tester.widget<Slider>(find.byKey(const Key('receive-volume-slider')));
      slider().onChanged!(25);
      await tester.pump();
      expect(bridge.writes, isEmpty);
      expect(find.text('25%'), findsOneWidget);
      slider().onChangeEnd!(25);
      await tester.pumpAndSettle();
      expect(bridge.writes, [25]);
      bridge.fail = true;
      slider().onChangeEnd!(10);
      await tester.pumpAndSettle();
      expect(slider().onChanged, isNull);
      expect(find.text('读取或调整失败，请刷新重试。'), findsOneWidget);
    },
  );

  testWidgets(
    'drag stays enabled, coalesces slow writes and never snaps to stale values',
    (tester) async {
      final bridge = ReceiveBridge()..pending = Completer<MediaVolume>();
      await tester.pumpWidget(
        MaterialApp(
          theme: audioShareTheme(Brightness.light),
          home: Scaffold(
            body: WindowsReceiveVolume(bridge: bridge, connected: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Slider slider() => tester.widget<Slider>(find.byType(Slider));
      slider().onChanged!(90.5);
      await tester.pump(const Duration(milliseconds: 50));
      expect(bridge.writes, [91]);
      expect(slider().divisions, isNull);
      expect(slider().onChanged, isNotNull);
      slider().onChanged!(70);
      slider().onChanged!(40);
      await tester.pump(const Duration(milliseconds: 150));
      expect(slider().value, 40);
      expect(bridge.writes, [91]);
      slider().onChangeEnd!(30);
      final first = bridge.pending!;
      bridge.pending = Completer<MediaVolume>();
      first.complete(const MediaVolume(current: 91, max: 100, fixed: false));
      await tester.pump();
      expect(bridge.writes, [91, 30]);
      expect(slider().value, 30);
      expect(slider().onChanged, isNotNull);
      bridge.pending!.complete(
        const MediaVolume(current: 30, max: 100, fixed: false),
      );
      await tester.pumpAndSettle();
      expect(slider().value, 30);
    },
  );

  testWidgets(
    'disconnect cancels a throttled write before it reaches native audio',
    (tester) async {
      final bridge = ReceiveBridge();
      final connected = ValueNotifier(true);
      addTearDown(connected.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: audioShareTheme(Brightness.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: connected,
              builder: (_, value, _) =>
                  WindowsReceiveVolume(bridge: bridge, connected: value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byType(Slider)).onChanged!(25);
      connected.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bridge.writes, isEmpty);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      connected.value = true;
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byType(Slider)).onChanged!(40);
      await tester.pump(const Duration(milliseconds: 50));
      expect(bridge.writes, [40]);
    },
  );

  testWidgets('late volume response cannot enable a disconnected route', (
    tester,
  ) async {
    final bridge = ReceiveBridge()..pending = Completer<MediaVolume>();
    final connected = ValueNotifier(true);
    addTearDown(connected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: audioShareTheme(Brightness.light),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: connected,
            builder: (_, value, _) =>
                WindowsReceiveVolume(bridge: bridge, connected: value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(25);
    await tester.pump();
    connected.value = false;
    await tester.pump();
    bridge.pending!.complete(
      const MediaVolume(current: 25, max: 100, fixed: false),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.text('25%'), findsNothing);
  });
}
