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
}
