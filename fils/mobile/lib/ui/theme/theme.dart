import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Extra semantic colors not covered by Material's ColorScheme.
@immutable
class FilsPalette extends ThemeExtension<FilsPalette> {
  final Color ink, inkSecondary, inkTertiary, canvas, surface, surfaceMuted, border, heroTop, heroBottom;
  final Color positive, positiveBg, negative, negativeBg, warning, warningBg;
  const FilsPalette({
    required this.ink,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.heroTop,
    required this.heroBottom,
    required this.positive,
    required this.positiveBg,
    required this.negative,
    required this.negativeBg,
    required this.warning,
    required this.warningBg,
  });

  static const light = FilsPalette(
    ink: FilsColors.ink,
    inkSecondary: FilsColors.inkSecondary,
    inkTertiary: FilsColors.inkTertiary,
    canvas: FilsColors.canvas,
    surface: FilsColors.surface,
    surfaceMuted: FilsColors.surfaceMuted,
    border: FilsColors.border,
    heroTop: FilsColors.heroTop,
    heroBottom: FilsColors.canvas,
    positive: FilsColors.positive,
    positiveBg: FilsColors.positiveBg,
    negative: FilsColors.negative,
    negativeBg: FilsColors.negativeBg,
    warning: FilsColors.warning,
    warningBg: FilsColors.warningBg,
  );

  static const dark = FilsPalette(
    ink: FilsColors.inkDark,
    inkSecondary: FilsColors.inkSecondaryDark,
    inkTertiary: Color(0xFF6B7780),
    canvas: FilsColors.canvasDark,
    surface: FilsColors.surfaceDark,
    surfaceMuted: FilsColors.surfaceMutedDark,
    border: FilsColors.borderDark,
    heroTop: FilsColors.heroTopDark,
    heroBottom: FilsColors.canvasDark,
    positive: Color(0xFF4ADE80),
    positiveBg: Color(0xFF14321F),
    negative: Color(0xFFF87171),
    negativeBg: Color(0xFF3B1414),
    warning: Color(0xFFFBBF24),
    warningBg: Color(0xFF3A2A0A),
  );

  @override
  FilsPalette copyWith() => this;
  @override
  FilsPalette lerp(ThemeExtension<FilsPalette>? other, double t) => t < 0.5 ? this : (other as FilsPalette? ?? this);
}

extension FilsThemeX on BuildContext {
  FilsPalette get fp => Theme.of(this).extension<FilsPalette>()!;
  TextTheme get tt => Theme.of(this).textTheme;
  bool get isRtl => Directionality.of(this) == TextDirection.rtl;
}

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.light ? FilsPalette.light : FilsPalette.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: FilsColors.primary,
    brightness: b,
    primary: b == Brightness.light ? FilsColors.primary : FilsColors.primaryLight,
    surface: p.surface,
  );
  final base = ThemeData(useMaterial3: true, brightness: b, colorScheme: scheme, fontFamily: kFontFamily);
  final text = base.textTheme
      .copyWith(
        displayLarge: const TextStyle(fontSize: 44, fontWeight: FontWeight.w700, letterSpacing: -1.2, height: 1.1),
        displayMedium: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.15),
        headlineMedium: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5),
        titleLarge: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        titleSmall: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        bodyLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.4),
        bodyMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.4),
        bodySmall: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
        labelLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        labelMedium: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        labelSmall: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.6),
      )
      .apply(bodyColor: p.ink, displayColor: p.ink, fontFamily: kFontFamily);
  final textWithEmoji = _withFallback(text);
  return base.copyWith(
    scaffoldBackgroundColor: p.canvas,
    textTheme: textWithEmoji,
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.canvas,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: text.titleMedium,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FilsRadius.lg)),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceMuted,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(FilsRadius.md), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: p.inkTertiary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        backgroundColor: b == Brightness.light ? FilsColors.ink : FilsColors.inkDark,
        foregroundColor: b == Brightness.light ? Colors.white : FilsColors.ink,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FilsRadius.pill)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        foregroundColor: p.ink,
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FilsRadius.pill)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: scheme.primary, textStyle: text.labelLarge, minimumSize: const Size(44, 44)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.canvas,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(FilsRadius.xl))),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceMuted,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FilsRadius.pill)),
      labelStyle: text.labelMedium,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: p.surfaceMuted,
        selectedBackgroundColor: p.surface,
        side: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FilsRadius.md))),
    switchTheme: SwitchThemeData(thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null)),
  );
}

const _emojiFallback = ['Apple Color Emoji', 'Noto Color Emoji', 'Segoe UI Emoji'];

TextTheme _withFallback(TextTheme t) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamilyFallback: _emojiFallback);
  return TextTheme(
    displayLarge: f(t.displayLarge),
    displayMedium: f(t.displayMedium),
    displaySmall: f(t.displaySmall),
    headlineLarge: f(t.headlineLarge),
    headlineMedium: f(t.headlineMedium),
    headlineSmall: f(t.headlineSmall),
    titleLarge: f(t.titleLarge),
    titleMedium: f(t.titleMedium),
    titleSmall: f(t.titleSmall),
    bodyLarge: f(t.bodyLarge),
    bodyMedium: f(t.bodyMedium),
    bodySmall: f(t.bodySmall),
    labelLarge: f(t.labelLarge),
    labelMedium: f(t.labelMedium),
    labelSmall: f(t.labelSmall),
  );
}
