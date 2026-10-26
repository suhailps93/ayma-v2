import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
