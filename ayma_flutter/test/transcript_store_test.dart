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

  test('an ayma turn carries the tool labels it was given', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'what won best picture', TurnSource.text);
    store.addTurn(TurnRole.ayma, 'looked it up for you', TurnSource.text,
        tools: const ['Searched the web']);
    expect(store.turns.last.tools, ['Searched the web']);
    expect(store.turns.first.tools, isEmpty); // default
  });

  test('a pending turn is non-final and resolvePending swaps it in place', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'look me up', TurnSource.text);
    store.addPending('Searching the web…');
    expect(store.turns.length, 2);
    expect(store.turns.last.isFinal, isFalse);
    expect(store.turns.last.role, TurnRole.ayma);

    store.resolvePending('Here is what I found.',
        tools: const ['Researched them online']);
    expect(store.turns.length, 2); // replaced, not appended
    expect(store.turns.last.isFinal, isTrue);
    expect(store.turns.last.text, 'Here is what I found.');
    expect(store.turns.last.tools, ['Researched them online']);

    // no pending turn -> no-op
    store.resolvePending('ignored');
    expect(store.turns.last.text, 'Here is what I found.');
  });

  test('pending turns are excluded from the wire window', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'hi', TurnSource.text);
    store.addPending('working on it…');
    expect(store.wireTurns().map((t) => t['text']), ['hi']);
  });
}
