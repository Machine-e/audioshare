import 'package:flutter/material.dart';

enum ConnectionIndicatorState { connected, disconnected, pending, unknown }

class ConnectionStatusLabel extends StatelessWidget {
  const ConnectionStatusLabel({
    super.key,
    required this.state,
    required this.label,
    this.style,
  });
  final ConnectionIndicatorState state;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (state) {
      ConnectionIndicatorState.connected =>
        dark ? const Color(0xff6cdda1) : const Color(0xff16834a),
      ConnectionIndicatorState.disconnected =>
        dark ? const Color(0xffff8c88) : const Color(0xffc83b3b),
      ConnectionIndicatorState.pending =>
        dark ? const Color(0xfff1c46a) : const Color(0xff986300),
      ConnectionIndicatorState.unknown => Theme.of(context).colorScheme.outline,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: style, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

Duration motionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 280);

/// Shares AnimatedTheme's clock with text and controls. Branching on brightness
/// inside a surface would switch its colors halfway through the text fade.
class GlassPalette extends ThemeExtension<GlassPalette> {
  const GlassPalette(this.background, this.surface, this.border, this.shadow);
  final List<Color> background, surface;
  final Color border, shadow;

  static const light = GlassPalette(
    [Color(0xffddeee5), Color(0xffeff2ed), Color(0xffdee8f0)],
    [Color(0xd9ffffff), Color(0x80ffffff)],
    Color(0xbfffffff),
    Color(0x06000000),
  );
  static const dark = GlassPalette(
    [Color(0xff203d35), Color(0xff111a19), Color(0xff202b34)],
    [Color(0xb32a3733), Color(0x801b2523)],
    Color(0x1fffffff),
    Color(0x14000000),
  );

  @override
  GlassPalette copyWith({
    List<Color>? background,
    List<Color>? surface,
    Color? border,
    Color? shadow,
  }) => GlassPalette(
    background ?? this.background,
    surface ?? this.surface,
    border ?? this.border,
    shadow ?? this.shadow,
  );

  @override
  GlassPalette lerp(covariant GlassPalette? other, double t) {
    if (other == null) return this;
    return GlassPalette(
      [
        for (var i = 0; i < background.length; i++)
          Color.lerp(background[i], other.background[i], t)!,
      ],
      [
        for (var i = 0; i < surface.length; i++)
          Color.lerp(surface[i], other.surface[i], t)!,
      ],
      Color.lerp(border, other.border, t)!,
      Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

ThemeData audioShareTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff557d76),
    brightness: brightness,
    primary: dark ? const Color(0xffa5dfcd) : const Color(0xff286657),
    surface: dark ? const Color(0xff182321) : const Color(0xfff6faf8),
  );
  final border = BorderSide(color: scheme.onSurface.withValues(alpha: .10));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [dark ? GlassPalette.dark : GlassPalette.light],
    fontFamily: 'MiSans',
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        height: 1.4,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.4,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.5,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.4,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        height: 1.4,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
    ),
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'MiSans',
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    cardTheme: const CardThemeData(color: Colors.transparent, elevation: 0),
    dividerTheme: DividerThemeData(color: border.color, thickness: 1),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      backgroundColor: scheme.surface.withValues(alpha: .4),
      selectedColor: scheme.primary.withValues(alpha: .13),
      showCheckmark: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 46),
        side: border,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 6,
      inactiveTrackColor: scheme.primary.withValues(alpha: .12),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      // Help opens immediately without resizing the scroll view every frame.
      expansionAnimationStyle: AnimationStyle.noAnimation,
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 8),
    ),
  );
}

/// Translucent surfaces share a static painted background. No full-screen blur
/// or perpetual animation is needed while audio plays in the background.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<GlassPalette>()!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.surface,
        ),
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<GlassPalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.background,
        ),
      ),
      child: child,
    );
  }
}

class AudioHalo extends StatelessWidget {
  const AudioHalo({super.key, required this.active, required this.icon});
  final bool active;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      duration: motionDuration(context),
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: active ? .14 : .06),
        border: Border.all(color: color.withValues(alpha: .15)),
        boxShadow: active
            ? [BoxShadow(color: color.withValues(alpha: .10), blurRadius: 32)]
            : [],
      ),
      child: AnimatedSwitcher(
        duration: motionDuration(context),
        child: Icon(icon, key: ValueKey(icon), size: 36, color: color),
      ),
    );
  }
}
