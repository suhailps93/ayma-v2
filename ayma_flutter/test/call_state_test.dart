import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controller that reports itself active without a real session —
/// for pinning that a live call outranks the last-ended record.
class _FakeActiveController extends VoiceSessionController {
  _FakeActiveController() : super(transcriptStore: TranscriptStore());

  @override
  bool get isActive => true;
}

void main() {
  setUp(() {
    VoiceSessionController.debugClearLastCallEnd();
    VoiceSessionController.active = null;
  });
  tearDown(() {
    VoiceSessionController.debugClearLastCallEnd();
    VoiceSessionController.active = null;
  });

  group('isDisconnectRequest', () {
    for (final text in [
      'disconnect',
      'Disconnect',
      'disconnect please',
      'please disconnect',
      'Disconnect!',
      'hang up',
      'hangup',
      'Hang up please',
      'end the call',
      'end this call',
      'stop the call',
      'disconnect now',
      'please hang up',
      // Question forms (founder, 2026-11-07: he typed "Can you
      // disconnect?" on a live call and the call never ended — the
      // model could only claim it was disconnecting).
      'Can you disconnect?',
      'can you disconnect',
      'could you hang up',
      'Can you end the call?',
      'can you please disconnect',
      'could you stop the call please',
    ]) {
      test('matches "$text"', () {
        expect(VoiceSessionController.isDisconnectRequest(text), isTrue);
      });
    }

    for (final text in [
      '',
      'I feel disconnected',
      'disconnect the wifi',
      "don't disconnect",
      'disconnect please I need help',
      'end call', // no article — the conservative text set wants the phrase
      'goodbye',
      'bye',
      'please end the call now and tell me a story',
      'we got disconnected yesterday',
      // Question forms stay whole-message strict too.
      'can you disconnect the wifi',
      'can you disconnect my account',
      'could you hang up my jacket',
      'can you end the call and order pizza',
    ]) {
      test('does not match "$text"', () {
        expect(VoiceSessionController.isDisconnectRequest(text), isFalse);
      });
    }
  });

  group('call-state snapshots', () {
    final t0 = DateTime(2026, 11, 7, 12, 0, 0);

    test('no record and no live call is none', () {
      expect(VoiceSessionController.chatCallState(now: t0).status, 'none');
      expect(VoiceSessionController.previousCallState(now: t0).status, 'none');
    });

    test('a fresh record is just_ended with its reason and age', () {
      VoiceSessionController.debugSetLastCallEnd(t0, 'client_idle_timeout');
      final snap = VoiceSessionController.chatCallState(
        now: t0.add(const Duration(seconds: 42)),
      );
      expect(snap.status, 'just_ended');
      expect(snap.isJustEnded, isTrue);
      expect(snap.endedSecondsAgo, 42);
      expect(snap.reason, 'client_idle_timeout');
      final prev = VoiceSessionController.previousCallState(
        now: t0.add(const Duration(seconds: 42)),
      );
      expect(prev.status, 'just_ended');
      expect(prev.reason, 'client_idle_timeout');
    });

    test('a record older than the window is none again', () {
      VoiceSessionController.debugSetLastCallEnd(t0, 'user_stop');
      final snap = VoiceSessionController.chatCallState(
        now: t0.add(VoiceSessionController.justEndedWindow +
            const Duration(seconds: 1)),
      );
      expect(snap.status, 'none');
    });

    test('a live call outranks a fresh record', () {
      VoiceSessionController.debugSetLastCallEnd(t0, 'user_stop');
      VoiceSessionController.active = _FakeActiveController();
      final snap = VoiceSessionController.chatCallState(
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(snap.status, 'active');
      expect(snap.isActive, isTrue);
    });
  });

  group('CallStateSnapshot.wireJson', () {
    test('active carries in_call only', () {
      expect(const CallStateSnapshot.active().wireJson, {
        'in_call': true,
        'end_reason': '',
      });
    });

    test('just_ended carries age and reason', () {
      expect(
        const CallStateSnapshot.justEnded(
          secondsAgo: 42,
          reason: 'client_idle_timeout',
        ).wireJson,
        {
          'in_call': false,
          'ended_seconds_ago': 42,
          'end_reason': 'client_idle_timeout',
        },
      );
    });

    test('none omits the object entirely', () {
      expect(const CallStateSnapshot.none().wireJson, isNull);
    });
  });

  group('buildChatRequestBody call_state', () {
    test('no snapshot argument, no call_state key', () {
      final body = buildChatRequestBody(message: 'hi');
      expect(body.containsKey('call_state'), isFalse);
    });

    test('an explicit none snapshot still omits the key', () {
      final body = buildChatRequestBody(
        message: 'hi',
        callState: const CallStateSnapshot.none(),
      );
      expect(body.containsKey('call_state'), isFalse);
    });

    test('active snapshot rides as in_call true', () {
      final body = buildChatRequestBody(
        message: 'hi',
        callState: const CallStateSnapshot.active(),
      );
      expect(body['call_state'], {'in_call': true, 'end_reason': ''});
    });

    test('just-ended snapshot rides with age and reason', () {
      final body = buildChatRequestBody(
        message: 'disconnect please',
        callState: const CallStateSnapshot.justEnded(
          secondsAgo: 42,
          reason: 'client_idle_timeout',
        ),
      );
      expect(body['call_state'], {
        'in_call': false,
        'ended_seconds_ago': 42,
        'end_reason': 'client_idle_timeout',
      });
    });
  });
}
