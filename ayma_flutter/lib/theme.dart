import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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
  static const darkFgMute = Color(0xFF8B8274);

  // Light
  static const lightBg = Color(0xFFFAF8F4);
  static const lightBgElev = Color(0xFFF3F0EB);
  static const lightBgCard = Color(0xFFEBE7E0);
  static const lightLine = Color(0xFFCDC8BE);
  static const lightLineSoft = Color(0xFFDDD9D2);
  static const lightFg = Color(0xFF1A1714);
  static const lightFgDim = Color(0xFF4A443B);
  static const lightFgMute = Color(0xFF706B60);

  // Shared across themes
  //
  // Cherry Fuchsia — the app-wide default accent family (2026-09-15),
  // replacing the earlier "Sunrise"/Ember peach. Read off the founder's
  // reference logo (a glossy cherry-red/fuchsia sphere): a saturated,
  // slightly-magenta red, hue ~341°, chosen by eye rather than lifted with a
  // colour-picker tool (no source image file was available to sample
  // pixel-exact). `accent` is only the *default* — a user's own pick from
  // the Accent Color settings screen overrides it at runtime via
  // [AymaTokens.withAccent]; this constant is what a fresh install shows
  // and what every `const` theme fallback (tests included) resolves to.
  static const accent = Color(0xFFDA4B65); // Cherry Fuchsia
  static const secondary = Color(0xFF7A3D20); // deepened ember

  // Ayma Sol "connected call" angelic-glow palette (`AymaOrbPainter`'s
  // `angelicGlow`/`connectedGlow` pass, active whenever `voiceLive` is true —
  // full intensity at `speaking`, dimmer through `listening`/`thinking`, see
  // `_connectedGlowIntensity` — never in text mode) — the petals light up
  // from within as if lit by an internal warm-white/pink source, layered
  // with BlendMode.screen over the ordinary Cherry Fuchsia glass. Named here
  // (not inline in the painter) per this repo's `color_audit_test.dart`
  // convention: every literal colour lives in this file.
  static const orbGlowPearl = Color(0xFFFFF3F5);
  static const orbGlowBlush = Color(0xFFFFA9C4);
  static const orbGlowHotPink = Color(0xFFFF3D8C);
  static const orbGlowSaturate = Color(0xFFFF5A8C);
  static const orbGlowLavender = Color(0xFFE77BEA);
  static const orbGlowLavenderWhite = Color(0xFFFBD8FB);
  static const orbGlowMagenta = Color(0xFFE8409E);
  static const orbGlowTeardrop = Color(0xFFF28AEA);
  static const orbGlowSphereHot = Color(0xFFFF2A6A);

  /// Re-hues one of the fixed Cherry Fuchsia orb glow tones above onto the
  /// live [accent]: the tone keeps its own lightness and rotates by the
  /// hue distance between [accent] and the default; its saturation follows
  /// how saturated [accent] is relative to the default. At the default
  /// accent the original tone is returned unchanged.
  static Color orbGlowTone(Color accent, Color tone) {
    if (accent == AymaColors.accent) return tone;
    final base = HSLColor.fromColor(AymaColors.accent);
    final live = HSLColor.fromColor(accent);
    final t = HSLColor.fromColor(tone);
    final sat = base.saturation == 0
        ? t.saturation
        : (t.saturation * live.saturation / base.saturation).clamp(0.0, 1.0);
    return t
        .withHue((t.hue + live.hue - base.hue) % 360)
        .withSaturation(sat)
        .toColor()
        .withValues(alpha: tone.a);
  }

  /// Screen-blend of [fg] over a backdrop of [bg], per channel — the colour
  /// `BlendMode.screen` produces where [fg] is drawn over [bg], keeping
  /// [fg]'s own alpha. The orb painter's compact (small-size) tiers cannot
  /// use real screen blending (on Impeller those layers dropped out at
  /// nav-bar size), so they paint this pre-blended colour with plain
  /// srcOver instead — landing the same colours the big voice-screen orb's
  /// real screen blend produces (see `AymaOrbPainter`).
  static Color screenOver(Color fg, Color bg) {
    double ch(double f, double b) => 1 - (1 - f) * (1 - b);
    return Color.fromARGB(
      (fg.a * 255).round(),
      (ch(fg.r, bg.r) * 255).round(),
      (ch(fg.g, bg.g) * 255).round(),
      (ch(fg.b, bg.b) * 255).round(),
    );
  }

  static const success = Color(0xFF4CAF7D);
  static const error = Color(0xFFCF4B4B);
  static const warning = Color(0xFFD9A441);

  /// Like-button filled red (Instagram red) — used when a profile is liked.
  /// Theme-independent (same in light and dark).
  static const likeRed = Color(0xFFFF3040);

  static Color accentSoft(Color base) => base.withValues(alpha: 0.18);
  static Color accentFaint(Color base) => base.withValues(alpha: 0.08);

  /// Ink for text/icons drawn on an [accent]-filled surface. Ember (the old
  /// peach default) failed white-text contrast, so this used to be a fixed
  /// dark ink; accent is now user-chosen (Task 4), so the ink itself has to
  /// follow whatever colour is actually picked — [onAccentFor] picks
  /// whichever of near-black/white contrasts better against it.
  static const onAccent = Color(0xFF1A1714);

  /// Choose the higher-contrast foreground for the selected accent.
  static Color onAccentFor(Color accent) {
    final luminance = accent.computeLuminance();
    final darkContrast = (luminance + 0.05) / (0.05);
    final whiteContrast = 1.05 / (luminance + 0.05);
    return darkContrast >= whiteContrast ? Colors.black : Colors.white;
  }

  /// WCAG 2.x relative-luminance contrast ratio between two opaque colours.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Derives a legible shade of [color] for use as TEXT (or a semantic icon)
  /// by shifting only its HSL lightness — down on a light background, up on a
  /// dark one — until it clears [target] contrast against EVERY colour in
  /// [backgrounds]. Hue and saturation are preserved, so a user's chosen
  /// accent stays recognisably itself; only its lightness moves far enough to
  /// read. Always terminates with a passing colour: pure black (light bg) /
  /// pure white (dark bg) clears any real target, so the bounded search can
  /// never fall through. [target] is set a notch above the 4.5:1 text floor
  /// so the result keeps a margin after device/float rounding.
  static Color textSafe(
    Color color,
    List<Color> backgrounds, {
    required bool bgIsLight,
    double target = 4.6,
  }) {
    final hsl = HSLColor.fromColor(color);
    const step = 0.02;
    for (var i = 0; i <= 60; i++) {
      final l =
          (hsl.lightness + (bgIsLight ? -step * i : step * i)).clamp(0.0, 1.0);
      final cand = hsl.withLightness(l).toColor();
      if (backgrounds.every((b) => contrastRatio(cand, b) >= target)) {
        return cand;
      }
    }
    return bgIsLight ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  }

  /// Hyperlink colour used by [MarkdownText] — a
  /// distinct, conventional "link blue", deliberately not tied to the
  /// user-configurable accent (a link should stay recognisable as a link
  /// regardless of which accent colour is active). Single source for what
  /// used to be a literal duplicated in both widgets.
  static const link = Color(0xFF3A7BD5);

  /// Full-screen busy/loading scrim (e.g. the Skills screen's "running a
  /// skill" overlay) — translucent black, theme-independent by design (it
  /// sits above whatever content is mid-action in either theme).
  static const scrimBusy = Color(0x99000000);
}

/// The shareable Appearance report card's own palette (design B): a light
/// paper card that looks the same in either app theme and in the exported
/// image. Only the user's accent varies (see `appearance_report_card.dart`).
class ReportCardColors {
  const ReportCardColors._();

  static const paper = Color(0xFFF5EEE4);
  static const ink = Color(0xFF1C1917);
  static const mute = Color(0xFF6B645C);
  static const dim = Color(0xFF3D3732);
  static const chipLine = Color(0xFFE6DCCF);
  static const rule = Color(0xFFDDD1C2);
  static const shadow = Color(0xFF3B221A);
  static const peach = Color(0xFFF5B7A0);
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
    required this.onAccent,
    required this.secondary,
    required this.success,
    required this.error,
    required this.warning,
    required this.likeRed,
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

  /// Ink for text/icons on an [accent]-filled surface — see
  /// [AymaColors.onAccentFor].
  final Color onAccent;
  final Color secondary;
  final Color success;
  final Color error;
  final Color warning;

  /// Like-button filled red (Instagram red) — used when a profile is liked.
  /// Theme-independent (same in light and dark).
  final Color likeRed;

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
    accentSoft: Color(0x2EDA4B65), // ~18%
    accentFaint: Color(0x14DA4B65), // ~8%
    onAccent: Colors.black, // Higher contrast on the rose default
    secondary: AymaColors.secondary,
    success: AymaColors.success,
    error: AymaColors.error,
    warning: AymaColors.warning,
    likeRed: AymaColors.likeRed,
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
    accentSoft: Color(0x2EDA4B65),
    accentFaint: Color(0x14DA4B65),
    onAccent: Colors.black,
    secondary: AymaColors.secondary,
    success: AymaColors.success,
    error: AymaColors.error,
    warning: AymaColors.warning,
    likeRed: AymaColors.likeRed,
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
    Color? onAccent,
    Color? secondary,
    Color? success,
    Color? error,
    Color? warning,
    Color? likeRed,
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
      onAccent: onAccent ?? this.onAccent,
      secondary: secondary ?? this.secondary,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      likeRed: likeRed ?? this.likeRed,
    );
  }

  /// Derives accent/accentSoft/accentFaint/onAccent from a single chosen
  /// [accent] colour — everything else on the token set (backgrounds, text,
  /// lines) is untouched. Used to apply the user's Accent Color pick
  /// (§ Settings > Accent Color) on top of either theme's base tokens.
  AymaTokens withAccent(Color accent) => copyWith(
        accent: accent,
        accentSoft: AymaColors.accentSoft(accent),
        accentFaint: AymaColors.accentFaint(accent),
        onAccent: AymaColors.onAccentFor(accent),
      );

  /// Whether this token set sits on a light background — selects the direction
  /// the text-safe derivations shift lightness.
  bool get _bgIsLight => bg.computeLuminance() > 0.5;

  /// The live [accent] darkened (light theme) / lightened (dark theme) until it
  /// reads ≥4.5:1 as TEXT on every surface it is drawn on — [bg], [bgElev], and
  /// an [accentFaint] fill over [bg]. Every accent-coloured *label* routes
  /// through this, while accent *icons* keep [accent] itself (they only need
  /// the 3:1 icon floor). Derived from whatever accent the user picked — never
  /// a hardcoded colour — so any pick stays legible (see [AymaColors.textSafe]).
  Color get accentText => AymaColors.textSafe(
        accent,
        [bg, bgElev, Color.alphaBlend(accentFaint, bg)],
        bgIsLight: _bgIsLight,
      );

  /// Dedicated track colour for progress rings and slider inactive tracks — a
  /// strong neutral derived from [line] (lightened on dark, darkened on light)
  /// until it clears the 3:1 non-text floor against BOTH [bg] and the live
  /// [accent] fill the track sits behind. The old track used [lineSoft], which
  /// was invisible against [bg] (1.2–1.3:1) and failed 3:1 against the fill in
  /// light; this reads clearly against both. Derived against the *live* accent
  /// so any user pick stays separated from its own track (see
  /// [AymaColors.textSafe]). Non-text, so the 3:1 floor applies — [target] is
  /// 3.3 for margin. One known physical ceiling: a very light accent (the
  /// founder terracotta #E07A5F, luminance 0.31) tops out at ~2.95:1 against a
  /// pure-white track in dark mode because no colour clears 3:1 against a fill
  /// that light while also clearing the near-black [bg] — the derivation then
  /// lands pure white, the maximum separation achievable.
  Color get track => AymaColors.textSafe(
        line,
        [bg, accent],
        bgIsLight: _bgIsLight,
        target: 3.3,
      );

  /// [error]/[success]/[warning] shifted per theme to clear the 4.5:1 text
  /// floor on [bg]. Dark [success]/[warning] already pass, so they return
  /// unchanged there; everything else is darkened/lightened just enough.
  /// Semantic *labels* and the debrief section icon tints route through these;
  /// raw [error]/[success]/[warning] stay for fills, borders and the error
  /// icons that only need the 3:1 non-text floor.
  Color get errorText =>
      AymaColors.textSafe(error, [bg], bgIsLight: _bgIsLight);
  Color get successText =>
      AymaColors.textSafe(success, [bg], bgIsLight: _bgIsLight);
  Color get warningText =>
      AymaColors.textSafe(warning, [bg], bgIsLight: _bgIsLight);

  /// Card-safe error text — [error] shifted per theme until it clears the
  /// 4.5:1 text floor on [bgCard] AND [bgElev] (and, being stronger than
  /// [errorText], on [bg] too, plus faint error/accent tints). Plain
  /// [errorText] is derived against [bg] only and fails on elevated surfaces
  /// (bgCard 4.20/4.03, bgElev-light 4.37); route error *labels* that render on
  /// a card, an elevated strip, a dialog surface, or a faint tint through this.
  /// Bg-level error labels stay on [errorText]. Derived, never hand-picked.
  Color get errorTextCard =>
      AymaColors.textSafe(error, [bgCard, bgElev], bgIsLight: _bgIsLight);

  /// A single strengthened boundary colour for card/field borders — derived
  /// from [line] (toward [fgMute]) until it clears the 3:1 non-text floor
  /// against ALL of [bg], [bgElev] and [bgCard] in both themes, so one token
  /// reads whether the edge sits on the page, an elevated surface or a card.
  /// The raw [line]/[lineSoft] borders were hairline-faint (1.08–1.57:1); this
  /// reads at a glance. Non-text, 3:1 floor; derived, not eyeballed.
  Color get boundary => AymaColors.textSafe(
        line,
        [bg, bgElev, bgCard],
        bgIsLight: _bgIsLight,
        target: 3.0,
      );

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
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      likeRed: Color.lerp(likeRed, other.likeRed, t)!,
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

  /// Message text — the one style for every chat / DM bubble and transcript.
  static TextStyle message({Color? color}) =>
      sans(size: 15, color: color, height: 1.4);

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

  /// Same as [light]/[dark] but with the accent family overridden to
  /// [accent] (§ Accent Color settings) — used by the running app; [light]/
  /// [dark] stay untouched (Cherry Fuchsia default) so every existing test
  /// that references them directly keeps compiling and passing unchanged.
  static ThemeData lightWithAccent(Color accent) =>
      _build(Brightness.light, AymaTokens.light.withAccent(accent));
  static ThemeData darkWithAccent(Color accent) =>
      _build(Brightness.dark, AymaTokens.dark.withAccent(accent));

  static ThemeData _build(Brightness brightness, AymaTokens t) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: t.onAccent,
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
      // Pinned explicitly (founder issue, iPhone testers: "no way to go back
      // from one screen to another"): iOS/macOS get the Cupertino transition,
      // whose interactive edge-swipe-back is the only systemwide "go back"
      // gesture an iPhone has — go_router's routes are MaterialPages, which
      // read this theme, so every pushed screen gets the gesture without
      // per-route wiring. Android keeps its current feel (the framework
      // default, predictive back). Spelling the full map out here (rather
      // than trusting the framework default that currently matches it) makes
      // the guarantee local and test-enforced — see
      // `test/ios_navigation_test.dart`.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        },
      ),
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
          side: BorderSide(color: t.boundary, width: 0.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
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
        // Text-safe accent so every TextButton label clears the 4.5:1 text
        // floor in both themes (accent-as-text fails the light bg at 3.83:1).
        // minimumSize floor is 44 (the absolute minimum) — the rendered height
        // is still 48 via M3's `materialTapTargetSize: padded`; declaring 48
        // here would fight that sizing. App-wide, so per-screen overrides are
        // unnecessary.
        style: TextButton.styleFrom(
          foregroundColor: t.accentText,
          minimumSize: const Size(0, 44),
        ),
      ),
      // SegmentedButton's M3 default is Size.fromHeight(40.0) — below the 44
      // floor; the padded tap target still renders it at 48. App-wide so the
      // per-screen SegmentedButton minimums are unnecessary.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.bgElev,
        selectedColor: t.accentSoft,
        side: BorderSide(color: t.line),
        shape: const StadiumBorder(),
        labelStyle: AymaType.sans(size: 13, color: t.fg),
        secondaryLabelStyle: AymaType.sans(size: 13, color: t.fg),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.bgElev,
        hintStyle: AymaType.sans(size: 15, color: t.fgMute),
        labelStyle: AymaType.sans(size: 15, color: t.fgDim),
        enabledBorder: border(t.boundary),
        focusedBorder: border(t.accent, 1.5),
        // Styled with the error token so it matches the palette (§14.1).
        errorBorder: border(t.error),
        focusedErrorBorder: border(t.error, 1.5),
        // The error helper renders below the field on the *containing* surface,
        // which for fields inside dialogs/sheets is bgCard/bgElev (AlertDialog
        // maps to surfaceContainerHigh = bgCard), where plain errorText fails
        // 4.5:1 (bgCard 4.20/4.03). The card-safe token clears 4.5 on bg,
        // bgElev and bgCard alike, so it is correct on every host surface.
        errorStyle: AymaType.sans(size: 12, color: t.errorTextCard),
      ),
      // Progress-ring/slider track colour: inactive slider tracks default to
      // surfaceContainerHighest (= bgCard), invisible against bg (1.15:1).
      // Route them through the dedicated track token. The active track keeps
      // the M3 default `primary` (= accent).
      sliderTheme: SliderThemeData(inactiveTrackColor: t.track),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: t.accent),
    );
  }
}
