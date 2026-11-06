import 'package:ayma_flutter/services/feedback_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('explicit trigger', () {
    test('close variants of capture feedback match', () {
      for (final text in [
        'capture feedback',
        'Capture feedback please',
        'please capture my feedback',
        'record feedback',
        'submit feedback',
        'I want to give feedback',
        'I have some feedback',
        'leave feedback',
      ]) {
        expect(isExplicitFeedbackRequest(text), isTrue, reason: text);
      }
    });

    test('a bare feedback mention does not match', () {
      for (final text in [
        'thanks for the feedback',
        'that feedback was helpful',
        'any feedback from my matches?',
        'hello',
        '',
      ]) {
        expect(isExplicitFeedbackRequest(text), isFalse, reason: text);
      }
    });

    test('prefill is the content stated with the trigger', () {
      expect(extractFeedbackPrefill('capture feedback: the mic drops'),
          'the mic drops');
      expect(extractFeedbackPrefill('capture feedback'), '');
    });
  });

  group('frustration signal', () {
    test('Ayma-directed frustration matches', () {
      for (final text in [
        'you keep asking me the same thing',
        'that is not what I said',
        'you are not listening',
        'stop repeating yourself',
      ]) {
        expect(looksFrustratedWithAyma(text), isTrue, reason: text);
      }
    });

    test('ordinary conversation does not match', () {
      for (final text in [
        'I had a frustrating day at work',
        'my date went badly and I feel sad',
        'sounds good, thanks!',
        '',
      ]) {
        expect(looksFrustratedWithAyma(text), isFalse, reason: text);
      }
    });
  });

  group('gate + evaluation', () {
    test('explicit path offers once per session', () {
      final gate = FeedbackBubbleGate();
      final first = evaluateUserTurnForBubble('capture feedback', gate);
      expect(first?.trigger, FeedbackBubbleTrigger.explicit);
      expect(evaluateUserTurnForBubble('capture feedback', gate), isNull);
    });

    test('each trigger gets its own single offer', () {
      final gate = FeedbackBubbleGate();
      expect(evaluateUserTurnForBubble('capture feedback', gate), isNotNull);
      final frustration = evaluateUserTurnForBubble('you keep asking', gate);
      expect(frustration?.trigger, FeedbackBubbleTrigger.frustration);
      expect(evaluateUserTurnForBubble('you keep asking', gate), isNull);
    });

    test('server payload goes through the same gate', () {
      final gate = FeedbackBubbleGate();
      final req =
          requestFromServerPayload({'trigger': 'frustration', 'prefill': ''}, gate);
      expect(req?.trigger, FeedbackBubbleTrigger.frustration);
      expect(
          requestFromServerPayload({'trigger': 'frustration', 'prefill': ''}, gate),
          isNull);
      expect(requestFromServerPayload({'trigger': 'nope'}, gate), isNull);
      expect(requestFromServerPayload(null, gate), isNull);
    });
  });
}
