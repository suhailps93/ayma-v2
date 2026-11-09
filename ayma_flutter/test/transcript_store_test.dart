import 'dart:io';

import 'package:ayma_flutter/services/report_events.dart';
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

  test('updatePendingText swaps the live label on the pending bubble', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'that reply was great', TurnSource.text);
    store.addPending('Thinking…');

    store.updatePendingText('Making a note of your feedback…');
    expect(store.turns.last.text, 'Making a note of your feedback…');
    expect(store.turns.last.isFinal, isFalse);

    // Once resolved, the persistent kicker carries the tool label.
    store.resolvePending('Noted — thanks for telling me.',
        tools: const ['Noted your feedback']);
    expect(store.turns.last.text, 'Noted — thanks for telling me.');
    expect(store.turns.last.tools, ['Noted your feedback']);

    // No pending turn -> updatePendingText is a no-op.
    store.updatePendingText('ignored');
    expect(store.turns.last.text, 'Noted — thanks for telling me.');
  });

  test('pending turns are excluded from the wire window', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'hi', TurnSource.text);
    store.addPending('working on it…');
    expect(store.wireTurns().map((t) => t['text']), ['hi']);
  });

  test('wireTurns includes reply context prefix naming You or Ayma for message replies', () {
    final store = TranscriptStore();
    store.addTurn(
      TurnRole.user,
      'Actually pizza sounds better',
      TurnSource.text,
      replySubject: 'You',
      replySnippet: 'I want sushi tonight',
      replyKind: 'message',
    );
    expect(
      store.wireTurns().single['text'],
      '[Replying to You: "I want sushi tonight"]\nActually pizza sounds better',
    );
  });

  test('addTurn with a local imageFile shows immediately, before any url', () {
    final store = TranscriptStore();
    final file = File('does_not_need_to_exist.jpg');
    final turn = store.addTurn(TurnRole.user, '', TurnSource.text,
        imageFile: file);
    expect(store.turns.single.imageFile, file);
    expect(store.turns.single.imageUrl, isNull);
    expect(turn.imageFile, file);
  });

  test('updateTurnImage swaps the local file for the uploaded url in place',
      () {
    final store = TranscriptStore();
    final file = File('does_not_need_to_exist.jpg');
    final turn = store.addTurn(TurnRole.user, 'check this out', TurnSource.text,
        imageFile: file);
    store.addTurn(TurnRole.user, 'a later message', TurnSource.text);

    store.updateTurnImage(turn, 'https://example.com/p.jpg');

    final updated = store.turns.first;
    expect(updated.imageUrl, 'https://example.com/p.jpg');
    expect(updated.text, 'check this out'); // untouched
    expect(store.turns.length, 2); // in place, not appended
  });

  test('updateTurnImage on a turn no longer in the window is a no-op', () {
    final store = TranscriptStore(maxTurns: 1);
    final file = File('does_not_need_to_exist.jpg');
    final gone = store.addTurn(TurnRole.user, 'first', TurnSource.text,
        imageFile: file);
    store.addTurn(TurnRole.user, 'second', TurnSource.text); // trims `gone`

    store.updateTurnImage(gone, 'https://example.com/p.jpg');
    expect(store.turns.single.text, 'second'); // unchanged, no throw
  });

  test('removeTurn drops a turn whose upload failed', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'before', TurnSource.text);
    final failed = store.addTurn(
        TurnRole.user, '', TurnSource.text, imageFile: File('x.jpg'));
    store.addTurn(TurnRole.user, 'after', TurnSource.text);

    store.removeTurn(failed);
    expect(store.turns.map((t) => t.text), ['before', 'after']);
  });

  test('addSharedTurn is a user turn with the card fields + instruction text',
      () {
    final store = TranscriptStore();
    store.addSharedTurn(
      kind: 'conversation',
      uid: 'u2',
      name: 'Jordan',
      photo: 'https://x/p.jpg',
      refId: 'a__b',
      text: "Here's my chat with Jordan. What next?",
    );
    final t = store.turns.single;
    expect(t.role, TurnRole.user);
    expect(t.sharedKind, 'conversation');
    expect(t.sharedRefId, 'a__b');
    expect(t.sharedName, 'Jordan');
    // The instruction still goes to the backend as a normal user turn.
    expect(store.wireTurns().single['text'],
        "Here's my chat with Jordan. What next?");
  });

  test('addSharedTurn with empty text produces wire turn with placeholder', () {
    final store = TranscriptStore();
    store.addSharedTurn(
      kind: 'profile',
      uid: 'u2',
      name: 'Dillu',
      photo: 'https://x/p.jpg',
      refId: '',
      text: '',
    );
    final t = store.turns.single;
    expect(t.role, TurnRole.user);
    expect(t.sharedKind, 'profile');
    expect(t.text, '');
    expect(store.wireTurns().single['text'], '[shared profile]');
  });

  test(
      'prependOlder splices an older page onto the front and survives its own trim',
      () {
    // A tiny cap so the test can actually exceed it, the way a real chat's
    // rolling 100-turn window fills up over a long history.
    final store = TranscriptStore(maxTurns: 5);
    for (var i = 0; i < 5; i++) {
      store.addTurn(TurnRole.user, 'recent $i', TurnSource.text);
    }
    expect(store.turns.map((t) => t.text), [
      'recent 0',
      'recent 1',
      'recent 2',
      'recent 3',
      'recent 4',
    ]);

    final older = [
      const TranscriptTurn(
          role: TurnRole.user, text: 'older 0', source: TurnSource.text),
      const TranscriptTurn(
          role: TurnRole.ayma, text: 'older 1', source: TurnSource.text),
    ];
    store.prependOlder(older);

    // Both the older page and every turn already in the window survive —
    // prepending must not let the pre-existing trim cap silently evict what
    // was just explicitly paged in.
    expect(store.turns.map((t) => t.text), [
      'older 0',
      'older 1',
      'recent 0',
      'recent 1',
      'recent 2',
      'recent 3',
      'recent 4',
    ]);
    expect(store.maxTurns, 7);
  });

  test('seed keeps live voice turns the loaded history does not have yet', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'old typed', TurnSource.text);
    store.applyVoiceSegment(TurnRole.user, 'open explore', isFinal: true);
    store.applyVoiceSegment(TurnRole.ayma, 'Opened Explore.', isFinal: true);
    store.applyVoiceSegment(TurnRole.user, 'and my st', isFinal: false);

    // A second chat surface on the shared store reloads server history
    // mid-call: the call's turns are not persisted until it ends.
    store.seed(const [
      TranscriptTurn(
          role: TurnRole.user, text: 'old typed', source: TurnSource.text),
      TranscriptTurn(
          role: TurnRole.ayma, text: 'old reply', source: TurnSource.text),
    ]);
    expect(store.turns.map((t) => t.text),
        ['old typed', 'old reply', 'open explore', 'Opened Explore.', 'and my st']);

    // The in-progress segment is still the live tail and keeps extending.
    store.applyVoiceSegment(TurnRole.user, 'and my story', isFinal: true);
    expect(store.turns.last.text, 'and my story');
    expect(store.turns.length, 5);
  });

  test('seed drops voice turns once history carries them (no duplicates)', () {
    final store = TranscriptStore();
    store.applyVoiceSegment(TurnRole.user, 'hello', isFinal: true);
    store.applyVoiceSegment(TurnRole.ayma, 'Hi there!', isFinal: true);
    store.seed(const [
      TranscriptTurn(role: TurnRole.user, text: 'hello', source: TurnSource.text),
      TranscriptTurn(
          role: TurnRole.ayma, text: 'Hi there!', source: TurnSource.text),
    ]);
    expect(store.turns.map((t) => (t.text, t.source)), [
      ('hello', TurnSource.text),
      ('Hi there!', TurnSource.text),
    ]);
  });

  test('seed still replaces typed turns wholesale', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'stale typed', TurnSource.text);
    store.seed(const [
      TranscriptTurn(role: TurnRole.user, text: 'fresh', source: TurnSource.text),
    ]);
    expect(store.turns.map((t) => t.text), ['fresh']);
  });

  test('prependOlder with an empty page is a no-op', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'hi', TurnSource.text);
    store.prependOlder(const []);
    expect(store.turns.map((t) => t.text), ['hi']);
    expect(store.maxTurns, 100);
  });

  test('repeated credit-cap hits do not pile up duplicate reload prompts',
      () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'run my appearance report', TurnSource.text);
    store.addPending('Reading your photos…');
    store.resolvePending("I'm out of credits — tap Reload to top up.",
        capped: true);
    expect(store.turns.where((t) => t.capped).length, 1);

    // A normal message in between (not capped) is untouched by the dedup.
    store.addTurn(TurnRole.user, 'ok', TurnSource.text);
    store.addTurn(TurnRole.ayma, 'sure thing', TurnSource.text);

    // Hitting the cap again (e.g. a different skill) resolves a second
    // pending turn — the earlier capped card must not survive alongside it.
    store.addPending('Searching the web…');
    store.resolvePending("I'm out of credits — tap Reload to top up.",
        capped: true);

    expect(store.turns.where((t) => t.capped).length, 1);
    // The surviving turns are the non-capped ones plus exactly one capped
    // reload card — the stale duplicate is gone, not just uncounted.
    expect(store.turns.map((t) => (t.text, t.capped)), [
      ('run my appearance report', false),
      ('ok', false),
      ('sure thing', false),
      ("I'm out of credits — tap Reload to top up.", true),
    ]);
  });

  test('clearCappedTurns drops resolved reload prompts once credits are topped up',
      () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'run my appearance report', TurnSource.text);
    store.addPending('Reading your photos…');
    store.resolvePending("I'm out of credits — tap Reload to top up.",
        capped: true);
    store.addTurn(TurnRole.user, 'thanks', TurnSource.text);

    store.clearCappedTurns();

    expect(store.turns.any((t) => t.capped), isFalse);
    expect(store.turns.map((t) => t.text),
        ['run my appearance report', 'thanks']);
  });

  test('clearCappedTurns is a no-op (no notify) when nothing is capped', () {
    final store = TranscriptStore();
    store.addTurn(TurnRole.user, 'hi', TurnSource.text);
    var pings = 0;
    store.addListener(() => pings++);

    store.clearCappedTurns();

    expect(pings, 0);
    expect(store.turns.map((t) => t.text), ['hi']);
  });

  group('resolveHistoryImage (reloading image turns from /chat/history)', () {
    test('a server-resolved image_url wins and never touches Storage', () async {
      // Founder bug 2026-09-27: an Ayma-generated image lives under
      // ayma_generated/{uid}, which Storage rules hide from the client SDK —
      // resolving its path can only fail, so the persisted URL must be used.
      final url = await resolveHistoryImage(
        imageUrl: 'https://cdn.example/tree.png?token=t1',
        imagePath: 'ayma_generated/u1/tree.png',
        resolvePath: (p) async =>
            throw StateError('must not resolve $p via Storage'),
      );
      expect(url, 'https://cdn.example/tree.png?token=t1');
    });

    test('an uploads/{uid} path still resolves through Storage', () async {
      final url = await resolveHistoryImage(
        imageUrl: '',
        imagePath: 'uploads/u1/chat_1.jpg',
        resolvePath: (p) async => 'https://cdn.example/$p',
      );
      expect(url, 'https://cdn.example/uploads/u1/chat_1.jpg');
    });

    test('a failed path resolution renders text-only, not an error', () async {
      final url = await resolveHistoryImage(
        imageUrl: '',
        imagePath: 'uploads/u1/gone.jpg',
        resolvePath: (p) async => throw StateError('object not found'),
      );
      expect(url, isNull);
    });

    test('no image at all stays null', () async {
      final url = await resolveHistoryImage(
        imageUrl: '',
        imagePath: '',
        resolvePath: (p) async => fail('nothing to resolve'),
      );
      expect(url, isNull);
    });
  });

  group('a story-edit tool completion live-refreshes the Story page', () {
    int rev() => ReportEvents.instance.revisionFor('story_private');

    test('a chat turn that edited the story fires the story report events', () {
      final store = TranscriptStore();
      store.addPending('working on it');
      final before = rev();
      final beforeNotes = ReportEvents.instance.revisionFor('story_ai_notes');
      store.resolvePending('done — changed that line for you',
          tools: const ['Updated your story']);
      expect(rev(), before + 1);
      expect(
          ReportEvents.instance.revisionFor('story_ai_notes'), beforeNotes + 1);
    });

    test('a finalized voice turn that edited the story fires too', () {
      final store = TranscriptStore();
      final before = rev();
      store.applyVoiceSegment(TurnRole.ayma, 'took that out of your story',
          isFinal: true, tools: const ['Removed that from your story']);
      expect(rev(), before + 1);
    });

    test('a plain turn with no story edit does not fire', () {
      final store = TranscriptStore();
      store.addPending('thinking');
      final before = rev();
      store.resolvePending('just chatting', tools: const ['Searched the web']);
      expect(rev(), before);
    });

    test('an interim (non-final) voice segment never fires', () {
      final store = TranscriptStore();
      final before = rev();
      store.applyVoiceSegment(TurnRole.ayma, 'updating your',
          isFinal: false, tools: const ['Updated your story']);
      expect(rev(), before);
    });
  });
}
