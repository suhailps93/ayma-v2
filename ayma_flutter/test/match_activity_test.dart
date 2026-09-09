import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/match_activity.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

ApiClient _api(double score) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async => http.Response(
            jsonEncode({
              'ok': true,
              'match_id': req.url.pathSegments.last,
              'score': score,
              'other_uid': 'b',
              'other_name': 'Bo',
              'shared': [],
              'tensions': [],
              'dimensions': [],
            }),
            200,
          )),
    );

void main() {
  setUp(() => MatchActivity.instance.recalculating.value = const {});

  test('marks a match busy while polling, then clears when the score changes',
      () async {
    final activity = MatchActivity.instance;
    expect(activity.isRecalculating('m1'), isFalse);

    final future = activity.start(
      'm1',
      previousScore: 0.40, // server returns 0.61 -> counts as changed
      api: _api(0.61),
      interval: const Duration(milliseconds: 10),
      maxPolls: 5,
    );

    expect(activity.isRecalculating('m1'), isTrue);
    await future;
    expect(activity.isRecalculating('m1'), isFalse);
  });

  test('a second start for the same id while one is live is a no-op', () async {
    final activity = MatchActivity.instance;
    final first = activity.start('m2',
        previousScore: 0.5,
        api: _api(0.5), // never changes -> runs the full (short) budget
        interval: const Duration(milliseconds: 5),
        maxPolls: 3);
    expect(activity.isRecalculating('m2'), isTrue);
    await activity.start('m2', api: _api(0.5)); // returns immediately
    await first;
    expect(activity.isRecalculating('m2'), isFalse);
  });
}
