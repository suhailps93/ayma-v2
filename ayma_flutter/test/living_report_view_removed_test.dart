// Regression pin for 2o P6 — the final LivingReportView removal (founder
// deletion order). The last host (Ayma's Notes' `story_ai_notes` body) was
// migrated to the shared GraphTreeView Node-Visualiser and
// `lib/widgets/living_report_view.dart` was deleted outright. This test fails
// the moment any reference to the old renderer creeps back into `lib/`, and if
// the deleted file ever reappears — so the deletion can never silently regress.
//
// The node-tree render of the migrated path itself is proven in
// `story_editor_screen_test.dart` ("Ayma's Notes: narrative wiki pages render
// via the story_ai_notes Node-Visualiser …") and ("Story: the narrative
// renders through the Node-Visualiser …").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Resolve the package `lib/` directory, whether the test runner's CWD is the
/// Flutter app root (`ayma_flutter/`) or the repo root.
Directory _libDir() {
  for (final p in ['lib', 'ayma_flutter/lib']) {
    final d = Directory(p);
    if (d.existsSync()) return d;
  }
  fail('Could not locate the package lib/ directory from ${Directory.current.path}');
}

void main() {
  test('living_report_view.dart is deleted and never comes back', () {
    final lib = _libDir();
    final file = File('${lib.path}/widgets/living_report_view.dart');
    expect(file.existsSync(), isFalse,
        reason: 'living_report_view.dart must stay deleted after 2o P6.');
  });

  test('no lib/ source references LivingReportView (instantiation, import, or '
      'stale doc-comment)', () {
    final lib = _libDir();
    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('LivingReportView')) {
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'LivingReportView was removed in 2o P6 — update these to the '
            'GraphTreeView Node-Visualiser:\n${offenders.join('\n')}');
  });
}
