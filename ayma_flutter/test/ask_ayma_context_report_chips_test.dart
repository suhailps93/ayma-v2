// Quick-suggestion chips for the generic Living Report origins (§ founder:
// "Make public"/"Make private"/"Delete" for a normal editable block, "This
// is me"/"Not me" for a pending candidate, nothing at all for a read-only
// Q&A turn on someone else's report).
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('quickSuggestionsFor(AskAymaOrigin.report)', () {
    test('a normal editable block currently public offers "Make private"',
        () {
      const ctx = AskAymaContext(
        origin: AskAymaOrigin.report,
        reportType: 'story_public',
        blockIds: ['page:p1:sent:0'],
        isPrivate: false,
      );
      expect(quickSuggestionsFor(ctx), ['Make private', 'Delete']);
    });

    test('a normal editable block currently private offers "Make public"',
        () {
      const ctx = AskAymaContext(
        origin: AskAymaOrigin.report,
        reportType: 'appearance',
        blockIds: ['attr:eye_color'],
        isPrivate: true,
      );
      expect(quickSuggestionsFor(ctx), ['Make public', 'Delete']);
    });

    test('a pending candidate block offers This is me / Not me instead', () {
      const ctx = AskAymaContext(
        origin: AskAymaOrigin.report,
        reportType: 'deep_dive',
        blockIds: ['candidate:c1'],
        isCandidate: true,
      );
      expect(quickSuggestionsFor(ctx), ['This is me', 'Not me']);
    });
  });

  test('quickSuggestionsFor(AskAymaOrigin.reportView) offers nothing', () {
    const ctx = AskAymaContext(origin: AskAymaOrigin.reportView);
    expect(quickSuggestionsFor(ctx), isEmpty);
  });
}
