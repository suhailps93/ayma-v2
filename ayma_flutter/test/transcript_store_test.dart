import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text and voice turns interleave in one ordered list', () {
    final store = TranscriptStore();

    store.addTurn(TurnRole.user, 'typed hi', TurnSource.text);
    store.applyVoiceSegment(TurnRole.ayma, 'spoken hello', isFinal: true);
    store.addTurn(TurnRole.user, 'typed again', TurnSource.text);

    expect(store.turns.map((t) => (t.text, t.source)), [
      ('typed hi', TurnSource.text),
      ('spoken hello', TurnSource.voice),
      ('typed again', TurnSource.text),
    ]);
  });

  test('interim voice segments replace the live tail; final freezes it', () {
    final store = TranscriptStore();

    store.applyVoiceSegment(TurnRole.user, 'I was', isFinal: false);
    store.applyVoiceSegment(TurnRole.user, 'I was thinking', isFinal: false);
    store.applyVoiceSegment(TurnRole.user, 'I was thinking aloud',
        isFinal: true);

    expect(store.turns.length, 1);
    expect(store.turns.single.text, 'I was thinking aloud');
    expect(store.turns.single.isFinal, isTrue);

    // A new segment after a finalized one starts a fresh turn.
    store.applyVoiceSegment(TurnRole.user, 'and then', isFinal: false);
    expect(store.turns.length, 2);
  });

  test('a different speaker starts a new turn even mid-stream', () {
    final store = TranscriptStore();
    store.applyVoiceSegment(TurnRole.user, 'hang on', isFinal: false);
    store.applyVoiceSegment(TurnRole.ayma, 'sure', isFinal: false);

    expect(store.turns.length, 2);
    expect(store.turns.first.role, TurnRole.user);
    expect(store.turns.last.role, TurnRole.ayma);
  });

  test('empty / whitespace segments are ignored', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, '   ', TurnSource.text);
    store.applyVoiceSegment(TurnRole.ayma, '', isFinal: false);
    expect(store.turns, isEmpty);
  });

  test('the window is bounded — oldest turns drop', () {
    final store = TranscriptStore(maxTurns: 3);
    for (var i = 0; i < 5; i++) {
      store.addTurn(TurnRole.user, 'm$i', TurnSource.text);
    }
    expect(store.turns.map((t) => t.text), ['m2', 'm3', 'm4']);
  });

  test('notifies listeners on change', () {
    final store = TranscriptStore();
    var pings = 0;
    store.addListener(() => pings++);
    store.addTurn(TurnRole.user, 'hi', TurnSource.text);
    store.clear();
    expect(pings, 2);
  });
}
