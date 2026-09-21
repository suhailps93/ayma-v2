// `AskAymaContext`'s forward-compat generic-report fields
// (`reportType`/`reportId`/`blockIds`/`scope`) and its `reportCorrectBody`
// mapping — a pure, tested bridge to the request shape the backend's generic
// tap-to-correct endpoint (`POST /report/{report_type}/{report_id}/correct`,
// `main.py`'s `ReportCorrectRequest` — `{block_ids, scope, message}`) already
// expects, so the next agent wiring this modal's quick-suggestion chips (or a
// typed correction) straight to that endpoint isn't building on an untested
// assumption about the shape it needs to send.
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reportCorrectBody', () {
    test('matches ReportCorrectRequest for a single-block correction', () {
      const ctx = AskAymaContext(
        reportType: 'appearance',
        reportId: 'abc123',
        blockIds: ['face.verdict'],
      );

      expect(ctx.reportCorrectBody("Actually my eyes are blue"), {
        'block_ids': ['face.verdict'],
        'scope': 'block',
        'message': "Actually my eyes are blue",
      });
    });

    test('carries a multi-block section-scoped correction through unchanged',
        () {
      const ctx = AskAymaContext(
        reportType: 'deep_dive',
        reportId: 'd1',
        blockIds: ['fact:1', 'fact:2'],
        scope: 'section',
      );

      expect(ctx.reportCorrectBody('Delete'), {
        'block_ids': ['fact:1', 'fact:2'],
        'scope': 'section',
        'message': 'Delete',
      });
    });

    test('a report-scoped correction carries an empty block list through',
        () {
      const ctx = AskAymaContext(
        reportType: 'story_public',
        reportId: 's1',
        scope: 'report',
      );

      expect(ctx.reportCorrectBody('Take this whole section down'), {
        'block_ids': <String>[],
        'scope': 'report',
        'message': 'Take this whole section down',
      });
    });

    test('the body key names and value types are exactly what the backend '
        'model declares (block_ids: List<String>, scope: String, '
        'message: String) — no accidental renaming/typing drift', () {
      const ctx = AskAymaContext(blockIds: ['x']);
      final body = ctx.reportCorrectBody('y');

      expect(body.keys.toSet(), {'block_ids', 'scope', 'message'});
      expect(body['block_ids'], isA<List<String>>());
      expect(body['scope'], isA<String>());
      expect(body['message'], isA<String>());
    });
  });

  test(
      "today's story/deep-dive/appearance origins default to no generic "
      'report reference — they stay on the dedicated /chat fields instead',
      () {
    const ctx = AskAymaContext();
    expect(ctx.reportType, '');
    expect(ctx.reportId, '');
    expect(ctx.blockIds, isEmpty);
    expect(ctx.scope, 'block');
  });
}
