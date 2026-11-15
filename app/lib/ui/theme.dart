import 'package:flutter/material.dart';

/// A colour theme: the seed for Material 3 plus the three glow colours of the animated background.
class AiyPreset {
  final String name;
  final Color seed;
  final List<Color> glow;
  const AiyPreset(this.name, this.seed, this.glow);
}

const List<AiyPreset> kPresets = [
  AiyPreset('Midnight', Color(0xFF4F6BFF), [Color(0xFF1B2F9E), Color(0xFF4F6BFF), Color(0xFF7A4DFF)]),
  AiyPreset('Aurora', Color(0xFF00BFA5), [Color(0xFF00695C), Color(0xFF00BFA5), Color(0xFF7C4DFF)]),
  AiyPreset('Sunset', Color(0xFFFF6D3A), [Color(0xFFAD1457), Color(0xFFFF6D3A), Color(0xFFFFB300)]),
  AiyPreset('Rose', Color(0xFFE91E63), [Color(0xFF6A1B9A), Color(0xFFE91E63), Color(0xFFFF8A65)]),
  AiyPreset('Forest', Color(0xFF2E9E5B), [Color(0xFF1B5E20), Color(0xFF2E9E5B), Color(0xFFC0CA33)]),
  AiyPreset('Graphite', Color(0xFF8E9AAF), [Color(0xFF37474F), Color(0xFF8E9AAF), Color(0xFFB0BEC5)]),
];

AiyPreset presetAt(int i) => kPresets[i.clamp(0, kPresets.length - 1)];

const String kMono = 'monospace';

ThemeData buildTheme(Color seed, Brightness b, bool amoled) {
  var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
  if (amoled && b == Brightness.dark) {
    scheme = scheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF0B0B0D),
      surfaceContainer: const Color(0xFF131316),
      surfaceContainerHigh: const Color(0xFF1B1B1F),
      surfaceContainerHighest: const Color(0xFF232328),
    );
  }
  const radius = 28.0; // the job-page look: big soft cards
  final r = BorderRadius.circular(radius);
  final small = BorderRadius.circular(16);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.6), width: 1.4)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: small),
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.4), thickness: 1, space: 1),
    switchTheme: SwitchThemeData(thumbIcon: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Icon(Icons.check_rounded, size: 14) : null)),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(10)), textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: const StadiumBorder(), textStyle: const TextStyle(fontWeight: FontWeight.w600))),
    floatingActionButtonTheme: FloatingActionButtonThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), elevation: 2),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(radius))),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w500,
        color: WidgetStateColor.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return scheme.onSurface.withValues(alpha: 0.38);
          if (states.contains(WidgetState.selected)) return scheme.onSecondaryContainer;
          return scheme.onSurface;
        }),
      ),
    ),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius + 4))),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius + 4))),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16), shape: RoundedRectangleBorder(borderRadius: small)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    }),
  );
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.3),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}
