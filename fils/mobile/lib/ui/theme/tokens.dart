import 'package:material_ui/material_ui.dart';

/// Design tokens. Structure and proportions follow the observed reference (soft
/// cool-gray surfaces, white rounded cards, a deep-teal accent and a gradient hero). The
/// palette and identity are Fils' own.
class FilsColors {
  // Brand
  static const primary = Color(0xFF0B7A8F); // deep teal
  static const primaryDark = Color(0xFF08606F);
  static const primaryLight = Color(0xFF5FB3C4);
  static const heroTop = Color(0xFF2E7591);
  static const heroMid = Color(0xFF6FA7BC);

  // Neutrals (light)
  static const ink = Color(0xFF11181C);
  static const inkSecondary = Color(0xFF687076);
  static const inkTertiary = Color(0xFF94A3B8);
  static const canvas = Color(0xFFF4F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFEEF1F4);
  static const border = Color(0xFFE2E8F0);

  // Neutrals (dark)
  static const inkDark = Color(0xFFECEFF1);
  static const inkSecondaryDark = Color(0xFF9BA6AD);
  static const canvasDark = Color(0xFF0D1214);
  static const surfaceDark = Color(0xFF172025);
  static const surfaceMutedDark = Color(0xFF1F2A30);
  static const borderDark = Color(0xFF2A363D);
  static const heroTopDark = Color(0xFF13414F);

  // Semantic
  static const positive = Color(0xFF16A34A);
  static const positiveBg = Color(0xFFDCFCE7);
  static const negative = Color(0xFFDC2626);
  static const negativeBg = Color(0xFFFEE2E2);
  static const warning = Color(0xFFD97706);
  static const warningBg = Color(0xFFFEF3C7);
  static const info = Color(0xFF2563EB);

  // Chart palette (validated for contrast on both themes)
  static const chart = <Color>[
    Color(0xFF0B7A8F),
    Color(0xFFF59E0B),
    Color(0xFF06B6D4),
    Color(0xFFEC4899),
    Color(0xFF10B981),
    Color(0xFF8B5CF6),
    Color(0xFF3B82F6),
    Color(0xFFEF4444),
  ];
}

class FilsSpace {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
  static const gutter = 16.0;
}

class FilsRadius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const pill = 999.0;
}

class FilsShadow {
  static const card = [
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 16, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x080F172A), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const floating = [
    BoxShadow(color: Color(0x1A0F172A), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

const kFontFamily = 'IBMPlexSansArabic';
const kMinTouchTarget = 44.0;
