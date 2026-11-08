import 'package:ayma_flutter/services/error_reporting.dart';
import 'package:ayma_flutter/services/sentry_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Regression coverage for the AYMA-FLUTTER-3R storm (2026-11-06,
/// build 2327): one framework assertion about the semantics tree fired
/// on every frame and produced 466 identical fatal Sentry events in
/// 75 seconds (plus a 49-event burst later that evening). The fix is
/// the identical-error storm gate: the first report of an error always
/// goes out in full; repeats inside the window are dropped; a different
/// error is never blocked.
void main() {
  group('RepeatedErrorGate', () {
    test('first occurrence passes, identical repeats are suppressed', () {
      final gate = RepeatedErrorGate();
      const key = 'AssertionError: semantics parent data is dirty';
      expect(gate.allow(key), isTrue);
      expect(gate.allow(key), isFalse);
      expect(gate.allow(key), isFalse);
      expect(gate.suppressedCount(key), 2);
    });

    test('a different error is never blocked by another error window', () {
      final gate = RepeatedErrorGate();
      expect(gate.allow('Error A'), isTrue);
      expect(gate.allow('Error B'), isTrue);
      expect(gate.allow('Error A'), isFalse);
      expect(gate.allow('Error B'), isFalse);
    });

    test('the same error reports again once the window has passed', () {
      var now = DateTime(2026, 11, 6, 21, 40);
      final gate = RepeatedErrorGate(
        window: const Duration(seconds: 60),
        clock: () => now,
      );
      const key = 'AssertionError: burst';
      expect(gate.allow(key), isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(gate.allow(key), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(gate.allow(key), isTrue);
      // And the new report starts a fresh window.
      expect(gate.allow(key), isFalse);
    });

    test('keyFor uses the runtime type and first line only', () {
      final a = StateError('boom\nsome long ownership chain');
      final b = StateError('boom\nan entirely different chain');
      expect(RepeatedErrorGate.keyFor(a), RepeatedErrorGate.keyFor(b));
      expect(
        RepeatedErrorGate.keyFor(a),
        'StateError: Bad state: boom',
      );
      final c = StateError('different');
      expect(RepeatedErrorGate.keyFor(c),
          isNot(RepeatedErrorGate.keyFor(a)));
    });
  });

  group('sentryEventGateKey', () {
    test('keys on the first exception type + value', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'AssertionError',
            value: "'package:flutter/src/rendering/object.dart': "
                "Failed assertion: line 5724 pos 14: "
                "'!semantics.parentDataDirty': is not true.",
          ),
        ],
      );
      expect(
        sentryEventGateKey(event),
        startsWith('AssertionError: '),
      );
      expect(
        sentryEventGateKey(event),
        contains('parentDataDirty'),
      );
    });

    test('an event with no exception and no message is never gated', () {
      expect(sentryEventGateKey(SentryEvent()), isNull);
    });
  });

  group('configureSentryOptions beforeSend storm gate', () {
    SentryEvent assertionEvent(String marker) => SentryEvent(
          exceptions: [
            SentryException(
              type: 'AssertionError',
              value: 'semantics storm $marker',
            ),
          ],
        );

    test(
        'the first identical fatal event is sent, its immediate repeat '
        'is dropped, and a different error still goes out', () async {
      final options = SentryFlutterOptions();
      configureSentryOptions(options, const SentryFlag());
      final beforeSend = options.beforeSend!;

      final first = await beforeSend(assertionEvent('case-one'), Hint());
      expect(first, isNotNull);

      final repeat = await beforeSend(assertionEvent('case-one'), Hint());
      expect(repeat, isNull);

      final other = await beforeSend(assertionEvent('case-two'), Hint());
      expect(other, isNotNull);
    });
  });
}
