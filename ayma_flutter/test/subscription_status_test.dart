import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/services/subscription_status.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// RevenueCat stand-in whose store calls FAIL — exactly an ad-hoc profile build
/// with no configured RevenueCat key (Scout NOTE 273: Plan "Couldn't load" on a
/// fresh install while chat/story loaded). The store layer must never block the
/// plan: load() falls through to the backend plan/usage and never throws.
class _BrokenRc extends RevenueCatService {
  @override
  Future<void> ensureReady({Duration timeout = const Duration(seconds: 4)}) async {}

  @override
  Future<ActiveSubscription?> activeSubscription() async =>
      throw StateError('RevenueCat not configured');
}

String _usageBody(String plan) => jsonEncode({
      'total': 33000,
      'features': {'chat': 30000},
      'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
      'plan': plan,
      'period_end': null,
      'tokens_per_credit': 1000,
    });

ApiClient _api(http.Response Function(int call) handler) {
  var n = 0;
  return ApiClient(
    httpClient: MockClient((req) async => handler(n++)),
    auth: MockFirebaseAuth(signedIn: true),
  );
}

void main() {
  test('a thrown activeSubscription() does not block the backend plan', () async {
    final s = await SubscriptionStatus.load(
      _BrokenRc(),
      _api((_) => http.Response(_usageBody('pro'), 200)),
    );
    // The store threw, but the backend /usage resolved — the real plan shows,
    // not an error (load() never rethrew).
    expect(s.planName, 'Pro');
  });

  test('store failure + a non-retryable backend failure degrades to Free, '
      'never throws', () async {
    // A definite 4xx is not cold-start-retryable, so load() falls straight
    // through to Free (no 45s backoff burn) rather than rethrowing.
    final s = await SubscriptionStatus.load(
      _BrokenRc(),
      _api((_) => http.Response('bad', 400)),
    );
    expect(s.planName, SubscriptionStatus.free.planName);
  });

  test('the backend usage ride a cold start (503 → 200) instead of Free',
      () async {
    // First /usage hits a scale-to-zero cold start (503 retryable), then warms.
    final s = await SubscriptionStatus.load(
      _BrokenRc(),
      _api((call) => call == 0
          ? http.Response('cold', 503)
          : http.Response(_usageBody('pro'), 200)),
    );
    expect(s.planName, 'Pro');
  });
}
