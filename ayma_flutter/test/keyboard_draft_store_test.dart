import 'package:ayma_flutter/services/keyboard_draft_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  group('KeyboardDraft freshness', () {
    test('fresh draft is insertable', () {
      final draft = KeyboardDraft(text: '  hello there  ', createdAtMillis: t0.millisecondsSinceEpoch);
      expect(draft.isFreshAt(t0.add(const Duration(minutes: 59))), isTrue);
      expect(draft.formatForInsertAt(t0.add(const Duration(minutes: 5))), 'hello there');
    });

    test('draft expires at exactly one hour', () {
      final draft = KeyboardDraft(text: 'hi', createdAtMillis: t0.millisecondsSinceEpoch);
      expect(draft.isFreshAt(t0.add(kKeyboardDraftTtl)), isFalse);
      expect(draft.isExpiredAt(t0.add(const Duration(hours: 2))), isTrue);
      expect(draft.formatForInsertAt(t0.add(const Duration(hours: 2))), isNull);
    });

    test('blank draft is never fresh or insertable', () {
      final draft = KeyboardDraft(text: '   ', createdAtMillis: t0.millisecondsSinceEpoch);
      expect(draft.isFreshAt(t0), isFalse);
      expect(draft.formatForInsertAt(t0), isNull);
    });

    test('insert formatting preserves interior newlines', () {
      final draft = KeyboardDraft(text: ' line one\n\nline two ', createdAtMillis: t0.millisecondsSinceEpoch);
      expect(draft.formatForInsertAt(t0), 'line one\n\nline two');
    });

    test('encode/decode round-trips and bad payloads decode to null', () {
      final draft = KeyboardDraft(text: 'hey', createdAtMillis: 42, source: 'chat');
      expect(KeyboardDraft.tryDecode(draft.encode()), draft);
      expect(KeyboardDraft.tryDecode(null), isNull);
      expect(KeyboardDraft.tryDecode('not json'), isNull);
      expect(KeyboardDraft.tryDecode('{"text":1,"createdAtMillis":2}'), isNull);
    });
  });

  group('KeyboardDraftService', () {
    test('set/get/clear via platform channel', () async {
      String? stored;
      const channel = MethodChannel('test/keyboard_draft');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'setDraft':
            final args = call.arguments as Map;
            stored = KeyboardDraft(
              text: args['text'] as String,
              createdAtMillis: (args['createdAtMillis'] as num).toInt(),
              source: args['source'] as String?,
            ).encode();
            return true;
          case 'getDraft':
            return stored;
          case 'clearDraft':
            stored = null;
            return null;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final service = KeyboardDraftService(channel: channel);
      expect(await service.setDraft('  drafted reply ', now: t0), isTrue);
      final got = await service.getDraft();
      expect(got?.text, 'drafted reply');
      expect(got?.createdAtMillis, t0.millisecondsSinceEpoch);
      await service.clearDraft();
      expect(await service.getDraft(), isNull);
    });

    test('blank drafts are rejected', () async {
      final service = KeyboardDraftService();
      expect(await service.setDraft('   '), isFalse);
    });

    test('missing plugin falls back to in-memory draft', () async {
      final service = KeyboardDraftService(
        channel: const MethodChannel('test/no_such_keyboard_channel'),
      );
      expect(await service.setDraft('kept in memory', now: t0), isTrue);
      expect((await service.getDraft())?.text, 'kept in memory');
    });
  });
}
