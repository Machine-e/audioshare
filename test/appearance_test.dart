import 'dart:async';

import 'package:audioshare/main.dart';
import 'package:audioshare/app_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart';

class AppearanceBridge extends FakeBridge {
  String? appearance;
  Completer<String?>? pendingTheme;
  @override
  Future<String?> readThemeMode() =>
      pendingTheme?.future ?? Future.value(appearance);
  @override
  Future<void> writeThemeMode(String mode) async => appearance = mode;
}

void main() {
  testWidgets(
    'glass surfaces fade with the theme without a mid-animation jump',
    (tester) async {
      final mode = ValueNotifier(ThemeMode.dark);
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (_, value, child) => MaterialApp(
            theme: audioShareTheme(Brightness.light),
            darkTheme: audioShareTheme(Brightness.dark),
            themeMode: value,
            themeAnimationDuration: const Duration(milliseconds: 280),
            themeAnimationCurve: Curves.linear,
            home: const AmbientBackground(
              child: GlassSurface(child: Text('AudioShare')),
            ),
          ),
        ),
      );
      Color surfaceColor() {
        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(GlassSurface),
                matching: find.byType(Container),
              )
              .first,
        );
        return ((container.decoration! as BoxDecoration).gradient!
                as LinearGradient)
            .colors
            .first;
      }

      for (final target in [ThemeMode.light, ThemeMode.dark]) {
        var previous = surfaceColor();
        mode.value = target;
        await tester.pump();
        var changedFrames = 0;
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
          final current = surfaceColor();
          expect((current.r - previous.r).abs(), lessThan(.15));
          expect((current.g - previous.g).abs(), lessThan(.15));
          expect((current.b - previous.b).abs(), lessThan(.15));
          if (current != previous) changedFrames++;
          previous = current;
        }
        expect(changedFrames, greaterThan(10));
        expect(
          surfaceColor(),
          (target == ThemeMode.light ? GlassPalette.light : GlassPalette.dark)
              .surface
              .first,
        );
        await tester.pumpAndSettle();
      }
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('$platform appearance persists without resetting connection', (
      tester,
    ) async {
      final bridge = AppearanceBridge()..preferred = 'phone';
      final companion = FakeCompanion();
      addTearDown(companion.events.close);
      Widget app() => AudioShareApp(
        platform: platform,
        bridge: bridge,
        companionBridge: companion,
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.windows) {
        await tester.tap(find.byKey(const Key('start-button')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('theme-toggle')));
      await tester.pumpAndSettle();
      expect(bridge.appearance, 'dark');
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(bridge.stops, 0);
      if (platform == TargetPlatform.windows) {
        expect(find.text('等待手机选择此电脑'), findsOneWidget);
        expect(bridge.waiters.length, 1);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await tester.tap(find.byKey(const Key('theme-toggle')));
      await tester.pumpAndSettle();
      expect(bridge.appearance, 'light');
    });
  }

  testWidgets('late saved theme cannot undo an explicit selection', (
    tester,
  ) async {
    final bridge = AppearanceBridge()..pendingTheme = Completer<String?>();
    await tester.pumpWidget(
      AudioShareApp(platform: TargetPlatform.windows, bridge: bridge),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pumpAndSettle();
    bridge.pendingTheme!.complete('light');
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('theme toggle follows system brightness and reverses mid-fade', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final bridge = AppearanceBridge();
    await tester.pumpWidget(
      AudioShareApp(platform: TargetPlatform.windows, bridge: bridge),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换到亮色'), findsOneWidget);
    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pump();
    expect(bridge.appearance, 'light');
    // Tap again while the rendered theme is still dark. The selected target
    // must drive the next toggle, otherwise both taps would request light.
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pumpAndSettle();
    expect(bridge.appearance, 'dark');
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(bridge.stops, 0);
  });
}
