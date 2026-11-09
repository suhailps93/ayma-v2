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
}
