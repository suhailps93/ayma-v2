import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('markFeedbackOutcome records the outcome and preserves the draft', () {
    final store = TranscriptStore();
    store.addPending('drafting');
    store.resolvePending(
      'Here is the card',
      feedbackKind: 'bug',
      feedbackTitle: 'Orb flickers',
      feedbackBody: 'it flickers',
    );
    final turn = store.turns.single;
    expect(turn.feedbackOutcome, '');

    store.markFeedbackOutcome(turn, 'sent');

    final updated = store.turns.single;
    expect(updated.feedbackOutcome, 'sent');
    expect(updated.feedbackKind, 'bug');
    expect(updated.feedbackTitle, 'Orb flickers');
    expect(updated.feedbackBody, 'it flickers');
    expect(updated.text, 'Here is the card');
  });

  test('the outcome survives later turn copies (updateTurn)', () {
    final store = TranscriptStore();
    store.addPending('drafting');
    store.resolvePending(
      'reply',
      feedbackKind: 'feature',
      feedbackTitle: 'T',
      feedbackBody: 'B',
    );
    store.markFeedbackOutcome(store.turns.single, 'dismissed');

    final updated = store.updateTurn(store.turns.single, text: 'reply v2');
    expect(updated, isNotNull);
    expect(updated!.feedbackOutcome, 'dismissed');
    expect(updated.feedbackKind, 'feature');
  });

  test('markFeedbackOutcome is a no-op for a turn no longer in the window', () {
    final store = TranscriptStore();
    const orphan = TranscriptTurn(
      role: TurnRole.ayma,
      text: 'gone',
      source: TurnSource.text,
      feedbackKind: 'bug',
      feedbackTitle: 'T',
      feedbackBody: 'B',
    );
    store.markFeedbackOutcome(orphan, 'sent');
    expect(store.turns, isEmpty);
  });
}
