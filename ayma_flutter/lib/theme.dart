import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Ayma visual design system (ARCHITECTURE.md §14.1).
///
/// One central file: raw token values ([AymaColors]), theme-aware tokens exposed
/// via `context.ac` ([AymaTokens]), the three type roles ([AymaType]), and the
/// light/dark [ThemeData] builders ([AymaTheme]). No screen declares a colour or
/// font literal directly — everything routes through here.
///
/// (Fonts are loaded via `google_fonts`, including Geist for the sans role;
/// §14.1 names Geist as a bundled asset — swapping to a bundled `.ttf` is a
/// Step 64 polish detail, the type roles are unchanged.)

// ---------------------------------------------------------------------------
// Raw token values
// ---------------------------------------------------------------------------

class AymaColors {
  const AymaColors._();

  // Dark
  static const darkBg = Color(0xFF131210);
  static const darkBgElev = Color(0xFF1B1916);
  static const darkBgCard = Color(0xFF222019);
  static const darkLine = Color(0xFF3A352A);
  static const darkLineSoft = Color(0xFF2A261F);
  static const darkFg = Color(0xFFEDE9DE);
  static const darkFgDim = Color(0xFFBAB3A3);
  static const darkFgMute = Color(0xFF7E7669);

  // Light
  static const lightBg = Color(0xFFFAF8F4);
  static const lightBgElev = Color(0xFFF3F0EB);
  static const lightBgCard = Color(0xFFEBE7E0);
  static const lightLine = Color(0xFFCDC8BE);
  static const lightLineSoft = Color(0xFFDDD9D2);
  static const lightFg = Color(0xFF1A1714);
  static const lightFgDim = Color(0xFF4A443B);
  static const lightFgMute = Color(0xFF7A7468);

  // Shared across themes
  static const accent = Color(0xFFDE8E69); // Ember — identical light & dark
  static const secondary = Color(0xFF7A3D20); // deepened ember
  static const success = Color(0xFF4CAF7D);
  static const error = Color(0xFFCF4B4B);
  static const warning = Color(0xFFD9A441);

  static Color accentSoft(Color _) => accent.withValues(alpha: 0.18);
  static Color accentFaint(Color _) => accent.withValues(alpha: 0.08);

  /// Dark ink for text/icons on the [accent] fill — white fails contrast on
  /// Ember in both themes (§14.1).
  static const onAccent = Color(0xFF1A1714);
}

// ---------------------------------------------------------------------------
// Theme-aware tokens
// ---------------------------------------------------------------------------

@immutable
class AymaTokens extends ThemeExtension<AymaTokens> {
  const AymaTokens({
    required this.bg,
    required this.bgElev,
    required this.bgCard,
    required this.line,
    required this.lineSoft,
    required this.fg,
    required this.fgDim,
    required this.fgMute,
    required this.accent,
    required this.accentSoft,
    required this.accentFaint,
    required this.secondary,
    required this.success,
    required this.error,
    required this.warning,
  });

  final Color bg;
  final Color bgElev;
  final Color bgCard;
  final Color line;
  final Color lineSoft;
  final Color fg;
  final Color fgDim;
  final Color fgMute;
  final Color accent;
  final Color accentSoft;
  final Color accentFaint;
  final Color secondary;
  final Color success;
  final Color error;
  final Color warning;

  static const dark = AymaTokens(
    bg: AymaColors.darkBg,
    bgElev: AymaColors.darkBgElev,
    bgCard: AymaColors.darkBgCard,
    line: AymaColors.darkLine,
    lineSoft: AymaColors.darkLineSoft,
    fg: AymaColors.darkFg,
    fgDim: AymaColors.darkFgDim,
    fgMute: AymaColors.darkFgMute,
    accent: AymaColors.accent,
    accentSoft: Color(0x2EDE8E69), // ~18%
    accentFaint: Color(0x14DE8E69), // ~8%
    secondary: AymaColors.secondary,
    success: AymaColors.success,
    error: AymaColors.error,
    warning: AymaColors.warning,
  );

  static const light = AymaTokens(
    bg: AymaColors.lightBg,
    bgElev: AymaColors.lightBgElev,
    bgCard: AymaColors.lightBgCard,
    line: AymaColors.lightLine,
    lineSoft: AymaColors.lightLineSoft,
    fg: AymaColors.lightFg,
    fgDim: AymaColors.lightFgDim,
    fgMute: AymaColors.lightFgMute,
    accent: AymaColors.accent,
    accentSoft: Color(0x2EDE8E69),
    accentFaint: Color(0x14DE8E69),
    secondary: AymaColors.secondary,
    success: AymaColors.success,
    error: AymaColors.error,
    warning: AymaColors.warning,
  );

  @override
  AymaTokens copyWith({
    Color? bg,
    Color? bgElev,
    Color? bgCard,
    Color? line,
    Color? lineSoft,
    Color? fg,
    Color? fgDim,
    Color? fgMute,
    Color? accent,
    Color? accentSoft,
    Color? accentFaint,
    Color? secondary,
    Color? success,
    Color? error,
    Color? warning,
  }) {
    return AymaTokens(
      bg: bg ?? this.bg,
      bgElev: bgElev ?? this.bgElev,
      bgCard: bgCard ?? this.bgCard,
      line: line ?? this.line,
      lineSoft: lineSoft ?? this.lineSoft,
      fg: fg ?? this.fg,
      fgDim: fgDim ?? this.fgDim,
      fgMute: fgMute ?? this.fgMute,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentFaint: accentFaint ?? this.accentFaint,
      secondary: secondary ?? this.secondary,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
    );
  }

  @override
  AymaTokens lerp(ThemeExtension<AymaTokens>? other, double t) {
    if (other is! AymaTokens) return this;
    return AymaTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      bgElev: Color.lerp(bgElev, other.bgElev, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineSoft: Color.lerp(lineSoft, other.lineSoft, t)!,
      fg: Color.lerp(fg, other.fg, t)!,
      fgDim: Color.lerp(fgDim, other.fgDim, t)!,
      fgMute: Color.lerp(fgMute, other.fgMute, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentFaint: Color.lerp(accentFaint, other.accentFaint, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

extension AymaContextTokens on BuildContext {
  /// Theme-aware Ayma tokens — `context.ac.bg`, `context.ac.accent`, … No screen
  /// branches on light/dark itself.
  AymaTokens get ac =>
      Theme.of(this).extension<AymaTokens>() ?? AymaTokens.dark;
}

// ---------------------------------------------------------------------------
// Typography — three roles (§14.1)
// ---------------------------------------------------------------------------

class AymaType {
  const AymaType._();

  /// Serif (Instrument Serif) — display / headlines, italic for emphasis.
  static TextStyle serif({
    double size = 28,
    FontWeight weight = FontWeight.w400,
    bool italic = false,
    Color? color,
  }) {
    return GoogleFonts.instrumentSerif(
      fontSize: size,
      fontWeight: weight,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      color: color,
      height: 1.15,
    );
  }

  /// Mono (JetBrains Mono) — all-caps letter-spaced micro-labels / eyebrows.
  static TextStyle mono({
    double size = 10,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 1.5,
      color: color,
    );
  }

  /// Sans (Geist) — body text and UI chrome, bundled at `assets/fonts/`.
  /// [soft] uses the lighter (300) weight.
  static TextStyle sans({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    bool soft = false,
    Color? color,
    double? height,
  }) {
    return TextStyle(
      fontFamily: 'Geist',
      fontSize: size,
      fontWeight: soft ? FontWeight.w300 : weight,
      color: color,
      height: height,
    );
  }

  static TextTheme textTheme(Color fg, Color fgDim) {
    return TextTheme(
      displayLarge: AymaType.serif(size: 52, color: fg),
      displayMedium: AymaType.serif(size: 40, color: fg),
      displaySmall: AymaType.serif(size: 34, color: fg),
      headlineLarge: AymaType.serif(size: 30, color: fg),
      headlineMedium: AymaType.serif(size: 26, color: fg),
      headlineSmall: AymaType.serif(size: 22, color: fg),
      titleLarge: AymaType.sans(size: 20, weight: FontWeight.w600, color: fg),
      titleMedium: AymaType.sans(size: 16, weight: FontWeight.w600, color: fg),
      titleSmall: AymaType.sans(size: 14, weight: FontWeight.w600, color: fg),
      bodyLarge: AymaType.sans(size: 16, color: fg, height: 1.45),
      bodyMedium: AymaType.sans(size: 14, color: fgDim, height: 1.45),
      bodySmall: AymaType.sans(size: 12, color: fgDim, height: 1.4),
      labelLarge: AymaType.mono(size: 10, color: fg),
      labelMedium: AymaType.mono(size: 9, color: fgDim),
      labelSmall: AymaType.mono(size: 8, color: fgDim),
    );
  }
}

// ---------------------------------------------------------------------------
// ThemeData builders
// ---------------------------------------------------------------------------

class AymaTheme {
  const AymaTheme._();

  static const _pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(99)),
  );

  static ThemeData get light => _build(Brightness.light, AymaTokens.light);
  static ThemeData get dark => _build(Brightness.dark, AymaTokens.dark);

  static ThemeData _build(Brightness brightness, AymaTokens t) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.accent,
      // White fails contrast on Ember in both themes -> dark ink (§14.1).
      onPrimary: AymaColors.onAccent,
      primaryContainer: t.accentSoft,
      onPrimaryContainer: t.fg,
      secondary: t.secondary,
      onSecondary: Colors.white,
      secondaryContainer: t.secondary,
      onSecondaryContainer: Colors.white,
      error: t.error,
      onError: Colors.white,
      surface: t.bg,
      onSurface: t.fg,
      surfaceContainerLowest: t.bg,
      surfaceContainerLow: t.bgElev,
      surfaceContainer: t.bgElev,
      surfaceContainerHigh: t.bgCard,
      surfaceContainerHighest: t.bgCard,
      onSurfaceVariant: t.fgDim,
      outline: t.line,
      outlineVariant: t.lineSoft,
    );

    final text = AymaType.textTheme(t.fg, t.fgDim);

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: c, width: w),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      textTheme: text,
      extensions: [t],
      appBarTheme: AppBarTheme(
        backgroundColor: t.bg,
        foregroundColor: t.fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: AymaType.serif(size: 22, color: t.fg),
      ),
      dividerTheme: DividerThemeData(color: t.lineSoft, thickness: 0.5),
      cardTheme: CardThemeData(
        color: t.bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          side: BorderSide(color: t.lineSoft, width: 0.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: AymaColors.onAccent,
          textStyle: AymaType.sans(size: 15, weight: FontWeight.w600),
          minimumSize: const Size.fromHeight(52),
          shape: _pill,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.fg,
          side: BorderSide(color: t.line),
          textStyle: AymaType.sans(size: 15, weight: FontWeight.w500),
          minimumSize: const Size.fromHeight(52),
          shape: _pill,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: t.accent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.bgElev,
        selectedColor: t.accentSoft,
        side: BorderSide(color: t.line),
        shape: const StadiumBorder(),
        labelStyle: AymaType.sans(size: 13, color: t.fg),
        secondaryLabelStyle: AymaType.sans(size: 13, color: t.fg),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.bgCard,
        contentTextStyle: AymaType.sans(size: 14, color: t.fg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: t.lineSoft, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.bgElev,
        hintStyle: AymaType.sans(size: 15, color: t.fgMute),
        labelStyle: AymaType.sans(size: 15, color: t.fgDim),
        enabledBorder: border(t.line),
        focusedBorder: border(t.accent, 1.5),
        // Styled with the error token so it matches the palette (§14.1).
        errorBorder: border(t.error),
        focusedErrorBorder: border(t.error, 1.5),
        errorStyle: AymaType.sans(size: 12, color: t.error),
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: t.accent),
    );
  }
}
