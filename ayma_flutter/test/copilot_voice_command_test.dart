import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// The co-pilot voice bridge commands (`copilot_locate` /
/// `copilot_copy_draft`): the backend voice tools queue them while a
/// co-pilot screen share runs, and [AppCommandService] owns their acks —
/// a spoken report (`result`) on success, or the honest `reason`
/// (not_sharing / secure_paused / no_draft / …) the tool turns into a
/// truthful line. The executors are injected here, like take_picture's.
void main() {
  group('copilot voice commands', () {
    late FakeFirebaseFirestore fs;
    late MockFirebaseAuth auth;

    DocumentReference<Map<String, dynamic>> pending() =>
        fs.doc('users/me/app_commands/pending');
    DocumentReference<Map<String, dynamic>> ack() =>
        fs.doc('users/me/app_commands/ack');

    AppCommandService svcWith({
      Future<CopilotCommandOutcome> Function(Map<String, dynamic>)? locate,
      Future<CopilotCommandOutcome> Function(Map<String, dynamic>)? copy,
    }) =>
        AppCommandService(
          firestore: fs,
          auth: auth,
          navigate: (_) {},
          copilotLocate: locate ?? (_) async => const CopilotCommandOutcome.done('ok'),
          copilotCopyDraft:
              copy ?? (_) async => const CopilotCommandOutcome.done('copied'),
        );

    setUp(() {
      fs = FakeFirebaseFirestore();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    });

    test('copilot_locate acks ok with the spoken report and clears pending',
        () async {
      Map<String, dynamic>? seen;
      final svc = svcWith(locate: (cmd) async {
        seen = cmd;
        return const CopilotCommandOutcome.done(
          'The highlight ring is now drawn over "Reply".',
        );
      })..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'copilot_locate',
        'goal': 'reply to this message',
        'id': 'cp-1',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(seen?['goal'], 'reply to this message');
      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'cp-1');
      expect(ackDoc?['ok'], isTrue);
      expect(ackDoc?['result'], contains('highlight ring'));
      expect((await pending().get()).exists, isFalse);
    });

    test('copilot_locate with the share off acks ok=false not_sharing',
        () async {
      final svc = svcWith(
        locate: (_) async => const CopilotCommandOutcome.failed('not_sharing'),
      )..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'copilot_locate',
        'goal': 'what do I tap',
        'id': 'cp-2',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['ok'], isFalse);
      expect(ackDoc?['reason'], 'not_sharing');
      expect((await pending().get()).exists, isFalse);
    });

    test('copilot_copy_draft acks ok once the draft is copied', () async {
      var copyCalls = 0;
      final svc = svcWith(copy: (cmd) async {
        copyCalls++;
        return const CopilotCommandOutcome.done('copied');
      })..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'copilot_copy_draft',
        'id': 'cp-3',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(copyCalls, 1);
      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'cp-3');
      expect(ackDoc?['ok'], isTrue);
    });
  });
}
