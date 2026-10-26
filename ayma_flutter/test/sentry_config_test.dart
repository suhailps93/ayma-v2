import 'package:ayma_flutter/services/sentry_config.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Sentry is disabled when no DSN is defined', () {
    expect(sentryDsn, isEmpty);
    expect(sentryShouldRun(const SentryFlag(enabled: true)), isFalse);
  });

  group('sentryShouldRun', () {
    const on = SentryFlag(enabled: true);
    test('needs DSN, compile-time switch and flag', () {
      expect(sentryShouldRun(on, dsn: 'https://k@o.ingest/1'), isTrue);
      expect(sentryShouldRun(on, dsn: ''), isFalse);
      expect(
          sentryShouldRun(on, dsn: 'https://k@o.ingest/1', compiledIn: false),
          isFalse);
      expect(
          sentryShouldRun(const SentryFlag(enabled: false),
              dsn: 'https://k@o.ingest/1'),
          isFalse);
    });
  });

  group('SentryFlag', () {
    test('defaults are on with low trace rate', () {
      const f = SentryFlag();
      expect(f.enabled, isTrue);
      expect(f.tracesSampleRate, 0.05);
      expect(f.errorSampleRate, 1.0);
    });

    test('fromMap only disables on literal false and rejects bad rates', () {
      expect(SentryFlag.fromMap(null).enabled, isTrue);
      expect(SentryFlag.fromMap({'enabled': 'false'}).enabled, isTrue);
      expect(SentryFlag.fromMap({'enabled': 0}).enabled, isTrue);
      expect(SentryFlag.fromMap({'enabled': false}).enabled, isFalse);
      final f = SentryFlag.fromMap({
        'enabled': true,
        'traces_sample_rate': 5,
        'error_sample_rate': 'x',
      });
      expect(f.enabled, isTrue);
      expect(f.tracesSampleRate, 0.05);
      expect(f.errorSampleRate, 1.0);
      final g = SentryFlag.fromMap({
        'enabled': true,
        'traces_sample_rate': 0.2,
        'error_sample_rate': 0.5,
      });
      expect(g.tracesSampleRate, 0.2);
      expect(g.errorSampleRate, 0.5);
    });

    test('loadCached is on with nothing cached', () async {
      expect((await SentryFlag.loadCached()).enabled, isTrue);
    });

    test('refresh caches the Firestore flag, and flipping it off sticks',
        () async {
      final db = FakeFirebaseFirestore();
      final ref = db.collection('app_config').doc('sentry');
      await ref.set({'enabled': true, 'traces_sample_rate': 0.1});
      await SentryFlag.refresh(db);
      final on = await SentryFlag.loadCached();
      expect(on.enabled, isTrue);
      expect(on.tracesSampleRate, 0.1);

      await ref.set({'enabled': false});
      await SentryFlag.refresh(db);
      expect((await SentryFlag.loadCached()).enabled, isFalse);
    });

    test('a missing flag doc falls back to on', () async {
      SharedPreferences.setMockInitialValues({'sentry_flag_enabled': false});
      expect((await SentryFlag.loadCached()).enabled, isFalse);
      await SentryFlag.refresh(FakeFirebaseFirestore());
      expect((await SentryFlag.loadCached()).enabled, isTrue);
    });
  });

  test('configureSentryOptions applies flag rates and privacy settings', () {
    final o = SentryFlutterOptions();
    configureSentryOptions(
      o,
      const SentryFlag(
          enabled: true, tracesSampleRate: 0.07, errorSampleRate: 0.9),
    );
    expect(o.sendDefaultPii, isFalse);
    expect(o.attachScreenshot, isFalse);
    expect(o.attachViewHierarchy, isFalse);
    expect(o.captureFailedRequests, isFalse);
    expect(o.maxRequestBodySize, MaxRequestBodySize.never);
    expect(o.tracesSampleRate, 0.07);
    expect(o.sampleRate, 0.9);
    expect(o.beforeSend, isNotNull);
    expect(o.beforeSendTransaction, isNotNull);
    expect(o.beforeBreadcrumb, isNotNull);
  });

  group('scrubbing', () {
    test('drops request body and user', () {
      final event = SentryEvent(
        request: SentryRequest(url: 'https://x/chat', data: {'text': 'hi'}),
        user: SentryUser(id: 'u', email: 'a@b.co'),
      );
      final out = scrubSentryEvent(event);
      expect(out.request, isNull);
      expect(out.user, isNull);
    });

    test('redacts emails and phones from messages and exceptions', () {
      final event = SentryEvent(
        message: SentryMessage('call +1 (408) 555-0199 or mail me@x.com',
            params: ['secret']),
        exceptions: [
          SentryException(
              type: 'E', value: 'failed for jane.doe+1@mail.example.org'),
        ],
        // ignore: deprecated_member_use
        extra: {'draft': 'hello there'},
      );
      final out = scrubSentryEvent(event);
      expect(out.message!.formatted, 'call [phone] or mail [email]');
      expect(out.message!.params, isNull);
      expect(out.exceptions!.single.value, 'failed for [email]');
      // ignore: deprecated_member_use
      expect(out.extra, isNull);
    });

    test('breadcrumbs lose their data and redact messages', () {
      final crumb = scrubSentryBreadcrumb(Breadcrumb(
        message: 'sent to me@x.com',
        data: {'text': 'secret'},
      ))!;
      expect(crumb.data, isNull);
      expect(crumb.message, 'sent to [email]');
      expect(scrubSentryBreadcrumb(null), isNull);

      final out = scrubSentryEvent(SentryEvent(
        breadcrumbs: [Breadcrumb(message: 'm', data: {'k': 'v'})],
      ));
      expect(out.breadcrumbs!.single.data, isNull);
    });

    test('ordinary text and short numbers survive', () {
      expect(redactText('Bad state: item 12 of 3'), 'Bad state: item 12 of 3');
    });
  });
}
