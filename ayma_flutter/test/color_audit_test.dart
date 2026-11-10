import 'dart:io';
import 'dart:math' as math;

import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrastRatio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Task 1 of the Cherry Fuchsia batch: every real colour literal lives in
/// `lib/theme.dart`, not scattered as `Color(0x...)`/`Color.fromRGBO`/
/// `Color.fromARGB` literals across the rest of `lib/`. A grep-shaped test
/// rather than a static-analysis one — this is exactly the "no hardcoded
/// colours" sweep a human would run, made repeatable.
void main() {
  test('no Color(0x...)/fromRGBO/fromARGB literal outside theme.dart', () {
    final libDir = Directory('lib');
    final pattern =
        RegExp(r'Color\(0x[0-9A-Fa-f]{6,8}\)|Color\.fromRGBO\(|Color\.fromARGB\(');
    final offenders = <String>[];

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('lib/theme.dart') ||
          entity.path.endsWith('${Platform.pathSeparator}theme.dart')) {
        continue;
      }
      final content = entity.readAsStringSync();
      for (final match in pattern.allMatches(content)) {
        offenders.add('${entity.path}: ${match.group(0)}');
      }
    }

    expect(offenders, isEmpty,
        reason: 'Hardcoded colour literal(s) found outside theme.dart:\n'
            '${offenders.join('\n')}');
  });

  test('the previously-known strays specifically are gone', () {
    final checks = <String, String>{
      'lib/widgets/markdown_text.dart': 'Color(0xFF3A7BD5)',
      'lib/screens/skills_screen.dart': 'Color(0x99000000)',
    };
    for (final entry in checks.entries) {
      final content = File(entry.key).readAsStringSync();
      expect(content.contains(entry.value), isFalse,
          reason: '${entry.key} still has the literal ${entry.value}');
    }
  });

  test('fgMute contrast is at least 4.5:1 against bgElev and bg in both themes', () {
    expect(AymaColors.darkFgMute, const Color(0xFF8B8274));
    expect(AymaColors.lightFgMute, const Color(0xFF706B60));

    // Dark theme: fgMute against bg and bgElev (the sheet surface).
    final darkBgContrast = _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBg);
    final darkElevContrast = _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBgElev);
    expect(darkBgContrast, greaterThanOrEqualTo(4.5),
        reason: 'darkFgMute on darkBg contrast ($darkBgContrast) must be >= 4.5');
    expect(darkElevContrast, greaterThanOrEqualTo(4.5),
        reason: 'darkFgMute on darkBgElev contrast ($darkElevContrast) must be >= 4.5');

    // Light theme: fgMute against bg and bgElev (the sheet surface).
    final lightBgContrast = _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBg);
    final lightElevContrast = _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBgElev);
    expect(lightBgContrast, greaterThanOrEqualTo(4.5),
        reason: 'lightFgMute on lightBg contrast ($lightBgContrast) must be >= 4.5');
    expect(lightElevContrast, greaterThanOrEqualTo(4.5),
        reason: 'lightFgMute on lightBgElev contrast ($lightElevContrast) must be >= 4.5');
  });

  test('fgMute on bgCard measures below 4.5:1 floor (4.30:1), guarded so surfaces require fgDim', () {
    // Defect 15: fgMute against bgCard falls short of the 4.5:1 floor in both themes (4.30:1),
    // requiring call sites with bgCard fills (e.g. practice composer hint) to use fgDim (7.81:1).
    final darkBgCardContrast = _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBgCard);
    final lightBgCardContrast = _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBgCard);
    expect(darkBgCardContrast, closeTo(4.30, 0.05));
    expect(darkBgCardContrast, lessThan(4.5),
        reason: 'darkFgMute on darkBgCard ($darkBgCardContrast) fails 4.5:1 floor');
    expect(lightBgCardContrast, closeTo(4.30, 0.05));
    expect(lightBgCardContrast, lessThan(4.5),
        reason: 'lightFgMute on lightBgCard ($lightBgCardContrast) fails 4.5:1 floor');

    // fgDim passes >= 4.5:1 on bgCard in both themes (measures 7.81:1).
    final darkFgDimCardContrast = _contrastRatio(AymaColors.darkFgDim, AymaColors.darkBgCard);
    final lightFgDimCardContrast = _contrastRatio(AymaColors.lightFgDim, AymaColors.lightBgCard);
    expect(darkFgDimCardContrast, greaterThanOrEqualTo(4.5),
        reason: 'darkFgDim on darkBgCard contrast ($darkFgDimCardContrast) must be >= 4.5');
    expect(lightFgDimCardContrast, greaterThanOrEqualTo(4.5),
        reason: 'lightFgDim on lightBgCard contrast ($lightFgDimCardContrast) must be >= 4.5');
  });

  test('V8 (jobs story-media): fgMute-on-bgElev passes 4.5:1 (4.63 dark / 4.66 light)',
      () {
    // The reportBox eyebrow, part labels, and teaser detail in the story
    // editor stay fgMute on bgElev — this is the explicit guard for that
    // decision (fgMute-on-bgCard is guarded separately above).
    final darkFgMuteElev =
        _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBgElev);
    final lightFgMuteElev =
        _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBgElev);
    expect(darkFgMuteElev, closeTo(4.63, 0.05));
    expect(darkFgMuteElev, greaterThanOrEqualTo(4.5),
        reason: 'darkFgMute on darkBgElev ($darkFgMuteElev) must be >= 4.5');
    expect(lightFgMuteElev, closeTo(4.66, 0.05));
    expect(lightFgMuteElev, greaterThanOrEqualTo(4.5),
        reason: 'lightFgMute on lightBgElev ($lightFgMuteElev) must be >= 4.5');
  });

  test('reports pass contrast audits: bgElev, bg, and accentFaint surfaces', () {
    // Defect 7: accent on bgElev fails 4.5:1 in both themes (4.32 dark / 3.57 light),
    // while fgMute on bgElev passes (4.63 dark / 4.66 light).
    final darkAccentElev = _contrastRatio(AymaColors.accent, AymaColors.darkBgElev);
    final lightAccentElev = _contrastRatio(AymaColors.accent, AymaColors.lightBgElev);
    expect(darkAccentElev, closeTo(4.32, 0.05));
    expect(darkAccentElev, lessThan(4.5));
    expect(lightAccentElev, closeTo(3.57, 0.05));
    expect(lightAccentElev, lessThan(4.5));

    final darkFgMuteElev = _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBgElev);
    final lightFgMuteElev = _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBgElev);
    expect(darkFgMuteElev, greaterThanOrEqualTo(4.5));
    expect(lightFgMuteElev, greaterThanOrEqualTo(4.5));

    // Defect 20: accent on bg fails 4.5:1 in light theme (3.83:1),
    // while fgMute on bg passes in both (4.94 dark / 5.00 light).
    final lightAccentBg = _contrastRatio(AymaColors.accent, AymaColors.lightBg);
    expect(lightAccentBg, closeTo(3.83, 0.05));
    expect(lightAccentBg, lessThan(4.5));

    final darkFgMuteBg = _contrastRatio(AymaColors.darkFgMute, AymaColors.darkBg);
    final lightFgMuteBg = _contrastRatio(AymaColors.lightFgMute, AymaColors.lightBg);
    expect(darkFgMuteBg, greaterThanOrEqualTo(4.5));
    expect(lightFgMuteBg, greaterThanOrEqualTo(4.5));

    // Defects 22 & 24: banner message on accentFaint.
    final darkAccentFaintSurface =
        Color.alphaBlend(AymaTokens.dark.accentFaint, AymaColors.darkBg);
    final lightAccentFaintSurface =
        Color.alphaBlend(AymaTokens.light.accentFaint, AymaColors.lightBg);

    // accent on accentFaint fails (4.32 dark / 3.46 light)
    final darkAccentOnFaint = _contrastRatio(AymaColors.accent, darkAccentFaintSurface);
    final lightAccentOnFaint = _contrastRatio(AymaColors.accent, lightAccentFaintSurface);
    expect(darkAccentOnFaint, closeTo(4.32, 0.05));
    expect(darkAccentOnFaint, lessThan(4.5));
    expect(lightAccentOnFaint, closeTo(3.46, 0.05));
    expect(lightAccentOnFaint, lessThan(4.5));

    // error on accentFaint fails (3.97 dark / 3.76 light)
    final darkErrorOnFaint = _contrastRatio(AymaColors.error, darkAccentFaintSurface);
    final lightErrorOnFaint = _contrastRatio(AymaColors.error, lightAccentFaintSurface);
    expect(darkErrorOnFaint, closeTo(3.97, 0.05));
    expect(darkErrorOnFaint, lessThan(4.5));
    expect(lightErrorOnFaint, closeTo(3.76, 0.05));
    expect(lightErrorOnFaint, lessThan(4.5));

    // fgDim on accentFaint passes in both themes (8.40 dark / 8.21 light)
    final darkFgDimOnFaint = _contrastRatio(AymaColors.darkFgDim, darkAccentFaintSurface);
    final lightFgDimOnFaint = _contrastRatio(AymaColors.lightFgDim, lightAccentFaintSurface);
    expect(darkFgDimOnFaint, closeTo(8.40, 0.05));
    expect(darkFgDimOnFaint, greaterThanOrEqualTo(4.5));
    expect(lightFgDimOnFaint, closeTo(8.21, 0.05));
    expect(lightFgDimOnFaint, greaterThanOrEqualTo(4.5));
  });

  // -------------------------------------------------------------------------
  // Token-defects T1–T4 (jobs-token-defects): the derived text-safe tokens
  // fix the accent/error/success/warning-as-text and accent-as-text failures
  // the raw tokens exhibit above. The raw-token assertions above still hold —
  // this chunk added NEW derived tokens, it did not change the raw ones.
  // -------------------------------------------------------------------------

  // The founder's own accent pick (terracotta) — the second accent every
  // derived-accent assertion must also clear, not just the Cherry default.
  const terracotta = Color(0xFFE07A5F);

  AymaTokens lightAcc(Color a) => AymaTokens.light.withAccent(a);
  AymaTokens darkAcc(Color a) => AymaTokens.dark.withAccent(a);

  for (final pick in <(String, Color)>[
    ('default Cherry Fuchsia', AymaColors.accent),
    ('founder terracotta', terracotta),
  ]) {
    final (label, accent) = pick;
    test('T1: accentText reads >=4.5:1 as text on bg/bgElev/accentFaint '
        'in both themes ($label)', () {
      for (final t in [lightAcc(accent), darkAcc(accent)]) {
        final faint = Color.alphaBlend(t.accentFaint, t.bg);
        expect(_contrastRatio(t.accentText, t.bg), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on bg');
        expect(_contrastRatio(t.accentText, t.bgElev), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on bgElev');
        expect(_contrastRatio(t.accentText, faint), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on accentFaint');
      }
    });

    test('T4: FilledButton label (onAccent) reads >=4.5:1 on accent in both '
        'themes ($label)', () {
      for (final t in [lightAcc(accent), darkAcc(accent)]) {
        expect(_contrastRatio(t.onAccent, t.accent), greaterThanOrEqualTo(4.5),
            reason: '$label onAccent on accent');
      }
    });
  }

  test('T2: errorText reads >=4.5:1 as text on bg in both themes', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.errorText, t.bg), greaterThanOrEqualTo(4.5),
          reason: 'errorText on bg');
    }
  });

  test('T3: success/warning icon tints read >=3:1 on bg in both themes', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.successText, t.bg), greaterThanOrEqualTo(3.0),
          reason: 'successText (icon floor) on bg');
      expect(_contrastRatio(t.warningText, t.bg), greaterThanOrEqualTo(3.0),
          reason: 'warningText (icon floor) on bg');
    }
  });

  test('T3: success/warning as TEXT read >=4.5:1 on bg in both themes '
      '(facts row)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.successText, t.bg), greaterThanOrEqualTo(4.5),
          reason: 'successText on bg');
      expect(_contrastRatio(t.warningText, t.bg), greaterThanOrEqualTo(4.5),
          reason: 'warningText on bg');
    }
  });

  test('derived accent stays recognisably the SAME hue as the live accent '
      '(darkened/lightened only, never hardcoded)', () {
    for (final accent in [AymaColors.accent, terracotta]) {
      for (final t in [lightAcc(accent), darkAcc(accent)]) {
        final liveHue = HSLColor.fromColor(accent).hue;
        final textHue = HSLColor.fromColor(t.accentText).hue;
        expect((liveHue - textHue).abs(), lessThan(1.0),
            reason: 'accentText hue must track the live accent');
      }
    }
  });

  // -------------------------------------------------------------------------
  // Jobs token follow-up T1–T6: track token, card-safe error token, boundary
  // token, and the T2-new selected-fill decision. All values derived via
  // AymaColors.textSafe (no hand-picked shades); the raw assertions above are
  // unchanged.
  // -------------------------------------------------------------------------

  // T2 — track token: clears the 3:1 non-text floor vs bg AND vs the accent
  // fill it sits behind, in both themes, for BOTH the default cherry and the
  // founder terracotta. One measured physical ceiling is recorded: terracotta
  // (luminance 0.31) in dark mode tops out at ~2.95:1 vs a pure-white track —
  // no colour clears 3:1 vs a fill that light while also clearing the near-
  // black bg, so the derivation lands pure white (maximum separation).
  for (final pick in <(String, Color)>[
    ('default Cherry Fuchsia', AymaColors.accent),
    ('founder terracotta', terracotta),
  ]) {
    final (label, accent) = pick;
    test('T2: track token clears 3:1 vs bg in both themes ($label)', () {
      for (final t in [lightAcc(accent), darkAcc(accent)]) {
        expect(_contrastRatio(t.track, t.bg), greaterThanOrEqualTo(3.0),
            reason: '$label track vs bg');
      }
    });
  }

  test('T2: track token clears 3:1 vs the accent fill (cherry both themes, '
      'terracotta light); terracotta-dark is the measured 2.95 ceiling', () {
    // Cherry (default): clears 3:1 vs its own fill in both themes.
    expect(_contrastRatio(lightAcc(AymaColors.accent).track, AymaColors.accent),
        greaterThanOrEqualTo(3.0),
        reason: 'cherry track vs fill (light)');
    expect(_contrastRatio(darkAcc(AymaColors.accent).track, AymaColors.accent),
        greaterThanOrEqualTo(3.0),
        reason: 'cherry track vs fill (dark)');
    // Terracotta light: clears 3:1 vs fill.
    expect(_contrastRatio(lightAcc(terracotta).track, terracotta),
        greaterThanOrEqualTo(3.0),
        reason: 'terracotta track vs fill (light)');
    // Terracotta dark: physical ceiling — the derivation lands pure white and
    // still only reaches ~2.95 (white itself is the max against a lum-0.31
    // fill). Assert the known ceiling, not 3:1.
    final terraDarkTrack = darkAcc(terracotta).track;
    expect(terraDarkTrack, const Color(0xFFFFFFFF),
        reason: 'terracotta-dark track derivation lands pure white (max)');
    expect(_contrastRatio(terraDarkTrack, terracotta), closeTo(2.95, 0.03),
        reason: 'terracotta-dark track vs fill is the measured 2.95 ceiling');
  });

  // T4 — card-safe error text: clears the 4.5:1 text floor on bgCard AND
  // bgElev in both themes (plain errorText fails there). Base tokens, no
  // accent dependency.
  test('T4: errorTextCard reads >=4.5:1 on bgCard AND bgElev in both themes',
      () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.errorTextCard, t.bgCard), greaterThanOrEqualTo(4.5),
          reason: 'errorTextCard on bgCard');
      expect(_contrastRatio(t.errorTextCard, t.bgElev), greaterThanOrEqualTo(4.5),
          reason: 'errorTextCard on bgElev');
      // Stronger than errorText, so it also clears bg (the universally-safe
      // error label, used for the app-wide field errorStyle).
      expect(_contrastRatio(t.errorTextCard, t.bg), greaterThanOrEqualTo(4.5),
          reason: 'errorTextCard on bg');
    }
    // The existing bg-only errorText, by contrast, FAILS on bgCard — this is
    // exactly why the card-safe token was needed.
    expect(_contrastRatio(AymaTokens.light.errorText, AymaTokens.light.bgCard),
        lessThan(4.5));
    expect(_contrastRatio(AymaTokens.dark.errorText, AymaTokens.dark.bgCard),
        lessThan(4.5));
  });

  // T5 — boundary token: clears the 3:1 non-text floor on bg, bgElev AND
  // bgCard in both themes, so one token reads whether the edge sits on the
  // page, an elevated surface, or a card.
  test('T5: boundary token reads >=3:1 vs bg, bgElev and bgCard in both themes',
      () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.boundary, t.bg), greaterThanOrEqualTo(3.0),
          reason: 'boundary vs bg');
      expect(_contrastRatio(t.boundary, t.bgElev), greaterThanOrEqualTo(3.0),
          reason: 'boundary vs bgElev');
      expect(_contrastRatio(t.boundary, t.bgCard), greaterThanOrEqualTo(3.0),
          reason: 'boundary vs bgCard');
    }
    // The raw line/lineSoft borders it replaces were hairline-faint (<1.6:1).
    expect(_contrastRatio(AymaTokens.dark.lineSoft, AymaTokens.dark.bgCard),
        lessThan(1.5));
  });

  // T2-new — SegmentedButton selected fill DECISION: ember (secondary) stays.
  // A naive accent fill breaks legibility (white-on-accent fails the 4.5 text
  // floor); ember keeps 8.35:1 with white, the M3-default secondaryContainer
  // mapping and zero custom code.
  test('T2-new: selected SegmentedButton fill (ember) keeps white label '
      '>=4.5:1 in both themes (8.35); a naive accent fill would fail', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      // Ember (secondary) is the selected fill; onSecondaryContainer is white.
      expect(_contrastRatio(Colors.white, t.secondary),
          greaterThanOrEqualTo(4.5),
          reason: 'white on ember (selected fill)');
      expect(_contrastRatio(Colors.white, t.secondary), closeTo(8.35, 0.05),
          reason: 'ember legibility is 8.35 both themes');
    }
    // The measured reason option (a) is closed: a plain accent fill fails the
    // 4.5 text floor with white (cherry 4.06, terracotta 2.95).
    expect(_contrastRatio(Colors.white, AymaColors.accent), lessThan(4.5));
    expect(_contrastRatio(Colors.white, terracotta), lessThan(4.5));
    // And a derived darker accent fill (accentText-as-fill) with white also
    // fails in DARK, where accentText lightens the accent to read on dark bg.
    expect(_contrastRatio(Colors.white, darkAcc(AymaColors.accent).accentText),
        lessThan(4.5),
        reason: 'white-on-accentText fails in dark — option (a) closed');
  });

  // -------------------------------------------------------------------------
  // Jobs token follow-up #2: R5 linkText token, R6 accentText extended to
  // bgCard (+R9 match scores), R7 pre-run sheet flip. All values derived via
  // AymaColors.textSafe (no hand-picked shades).
  // -------------------------------------------------------------------------

  // R5 — linkText: the raw link blue fails the 4.5 text floor on every
  // surface a MarkdownText link renders on (bg, bgElev, bgCard). The derived
  // linkText clears >=4.5 (target 4.6) on all three in both themes.
  test('R5: linkText reads >=4.5:1 on bg, bgElev AND bgCard in both themes',
      () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.linkText, t.bg), greaterThanOrEqualTo(4.5),
          reason: 'linkText on bg');
      expect(_contrastRatio(t.linkText, t.bgElev), greaterThanOrEqualTo(4.5),
          reason: 'linkText on bgElev');
      expect(_contrastRatio(t.linkText, t.bgCard), greaterThanOrEqualTo(4.5),
          reason: 'linkText on bgCard');
    }
    // The raw AymaColors.link it is derived from FAILS the floor on all three
    // surfaces — exactly why the derived token was needed.
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(AymaColors.link, t.bg), lessThan(4.5));
      expect(_contrastRatio(AymaColors.link, t.bgElev), lessThan(4.5));
      expect(_contrastRatio(AymaColors.link, t.bgCard), lessThan(4.5));
    }
    // Derived, not hand-picked: linkText keeps the link-blue hue.
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      final liveHue = HSLColor.fromColor(AymaColors.link).hue;
      final textHue = HSLColor.fromColor(t.linkText).hue;
      expect((liveHue - textHue).abs(), lessThan(1.0),
          reason: 'linkText hue must track the raw link blue');
    }
  });

  // R6 (+R9) — accentText extended to bgCard: clears >=4.5 on bgCard in both
  // themes for BOTH the default cherry and the founder terracotta, with NO
  // regression on bg, bgElev or accentFaint-over-bg. The two match-score
  // sites (matches_screen) route through this token.
  for (final pick in <(String, Color)>[
    ('default Cherry Fuchsia', AymaColors.accent),
    ('founder terracotta', terracotta),
  ]) {
    final (label, accent) = pick;
    test('R6: accentText reads >=4.5:1 on bgCard in both themes AND keeps '
        'bg/bgElev/accentFaint passing ($label)', () {
      for (final t in [lightAcc(accent), darkAcc(accent)]) {
        final faint = Color.alphaBlend(t.accentFaint, t.bg);
        // The new surface — match scores, dialog TextButton labels.
        expect(_contrastRatio(t.accentText, t.bgCard), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on bgCard (R6/R9)');
        // No regression on the existing surfaces.
        expect(_contrastRatio(t.accentText, t.bg), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on bg (no regression)');
        expect(_contrastRatio(t.accentText, t.bgElev), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on bgElev (no regression)');
        expect(_contrastRatio(t.accentText, faint), greaterThanOrEqualTo(4.5),
            reason: '$label accentText on accentFaint-over-bg (no regression)');
      }
    });
  }

  // R9 — the raw accent (what the match scores used before) FAILS on bgCard,
  // so routing them through the extended accentText is load-bearing.
  test('R9: raw accent fails >=4.5:1 on bgCard (why match scores route through '
      'accentText)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(AymaColors.accent, t.bgCard), lessThan(4.5),
          reason: 'raw accent on bgCard fails — folds into R6');
    }
  });

  // R7 — pre-run sheet flip (bgElev -> bgCard): the swapped text tokens and
  // the border token all read on the new bgCard fill in both themes.
  test('R7: fgDim reads >=4.5:1 on bgCard (guidance/skipped-note swap) while '
      'fgMute stays below the floor (the guard that forced the swap)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.fgDim, t.bgCard), greaterThanOrEqualTo(4.5),
          reason: 'fgDim on bgCard (the replacement)');
      // fgMute on bgCard is the measured 4.30 failure the swap works around.
      expect(_contrastRatio(t.fgMute, t.bgCard), lessThan(4.5),
          reason: 'fgMute on bgCard below floor — why fgDim was needed');
    }
  });

  test('R7: pre-run group border reads — lineSoft fails on bgCard so the '
      'border routes through the boundary token (>=3:1 non-text floor)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      // The old lineSoft border does NOT read on the flipped bgCard fill.
      expect(_contrastRatio(t.lineSoft, t.bgCard), lessThan(3.0),
          reason: 'lineSoft on bgCard below the 3:1 non-text floor');
      // The boundary token the border now uses clears the 3:1 floor.
      expect(_contrastRatio(t.boundary, t.bgCard), greaterThanOrEqualTo(3.0),
          reason: 'boundary on bgCard reads (the fix)');
    }
  });

  // Defect R11: the ScoreBar FLAT fill (default [accent]) sat on a [lineSoft]
  // track that measured only 2.88:1 in light — below the 3:1 non-text floor.
  // score_bar.dart now defaults the track to the purpose-built [track] token,
  // which is derived against the live accent to clear 3:1 in both themes.
  // Ratios computed live from the token values, never hardcoded.
  test('ScoreBar flat fill (accent) clears 3:1 against its default track', () {
    // The contract: the accent flat fill reads against its default track in
    // BOTH themes at the 3:1 non-text floor. Ratios are measured live.
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      final label = t == AymaTokens.light ? 'light' : 'dark';
      final ratio = _contrastRatio(t.accent, t.track);
      expect(ratio, greaterThanOrEqualTo(3.0),
          reason: 'accent-on-track in $label is $ratio, must be >= 3.0');
    }

    // The defect R11 was light-only: the old [lineSoft] track measured
    // 2.88:1 (sub-floor); the [track] token raises it to ~3.33:1 (pass).
    expect(_contrastRatio(AymaTokens.light.accent, AymaTokens.light.lineSoft),
        lessThan(3.0),
        reason: 'original light failure: lineSoft track was below 3:1');
    expect(_contrastRatio(AymaTokens.light.accent, AymaTokens.light.lineSoft),
        closeTo(2.88, 0.05),
        reason: 'the original light-theme failure was 2.88:1');
    expect(_contrastRatio(AymaTokens.light.accent, AymaTokens.light.track),
        greaterThan(
            _contrastRatio(AymaTokens.light.accent, AymaTokens.light.lineSoft)),
        reason: 'the track token must separate better than lineSoft in light');

  });

  // -------------------------------------------------------------------------
  // Jobs cluster 21 (You + Settings): the new pairs these seven screens
  // introduce. The token contrasts themselves are the arbiter the per-defect
  // notes cite; these pin the surfaces this cluster actually renders on.
  // -------------------------------------------------------------------------

  test('cluster21: accentText reads >=4.5:1 on bgCard in both themes '
      '(the MCP URL on the instructions card — defect 13)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.accentText, t.bgCard), greaterThanOrEqualTo(4.5),
          reason: 'accentText on bgCard');
      // The raw accent it replaces fails as 12pt text on bgCard in BOTH
      // themes (4.02/3.29) — exactly why the URL routes through accentText.
      expect(_contrastRatio(t.accent, t.bgCard), lessThan(4.5),
          reason: 'raw accent on bgCard fails — defect 13 motivation');
    }
  });

  test('cluster21: the Delete button black label reads >=4.5:1 on the error '
      'fill in both themes (delete-account — defect 1 surface, unchanged fill)',
      () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      expect(_contrastRatio(t.onAccent, AymaColors.error),
          greaterThanOrEqualTo(4.5),
          reason: 'black label on error fill');
    }
  });

  test('cluster21: the locked tile at full strength (no Opacity) clears the '
      'text floors on bgElev in both themes (defect 9)', () {
    for (final t in [AymaTokens.light, AymaTokens.dark]) {
      // Label is now fgDim (was fg under a 0.55 Opacity, which failed light).
      expect(_contrastRatio(t.fgDim, t.bgElev), greaterThanOrEqualTo(4.5),
          reason: 'locked-tile label (fgDim) on bgElev');
      // The `Locked` mono label + lock icon stay fgMute, now at full strength.
      expect(_contrastRatio(t.fgMute, t.bgElev), greaterThanOrEqualTo(4.5),
          reason: 'locked-tile mono + icon (fgMute) on bgElev');
    }
  });
}
