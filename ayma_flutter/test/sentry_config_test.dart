import 'package:ayma_flutter/services/sentry_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  test('Sentry is disabled when no DSN is defined', () {
    expect(sentryDsn, isEmpty);
  });

  test('scrubSentryEvent drops request body and user', () {
    final event = SentryEvent(
      request: SentryRequest(url: 'https://x/chat', data: {'text': 'hi'}),
      user: SentryUser(id: 'u'),
    );
    final out = scrubSentryEvent(event);
    expect(out.request, isNull);
    expect(out.user, isNull);
  });
}
