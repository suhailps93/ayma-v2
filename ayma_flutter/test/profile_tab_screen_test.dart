import 'dart:convert';

import 'package:ayma_flutter/screens/profile_tab_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/completeness_ring.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api({Map<String, dynamic>? completeness, int completenessStatus = 200}) {
  final mockHttp = MockClient((req) async {
    if (req.url.path == '/completeness') {
      return http.Response(
        jsonEncode(completeness ?? const {}),
        completenessStatus,
        headers: _jsonUtf8,
      );
    }
    // /usage (the credits pill) and anything else — harmless empty body.
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ApiClient api) {
  final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
  final router = GoRouter(
    initialLocation: '/profile',
    routes: [
      GoRoute(
        path: '/profile',
        builder: (_, __) => ProfileTabScreen(auth: auth, apiClient: api),
      ),
      GoRoute(
        path: '/complete-profile',
        builder: (_, __) => const Scaffold(body: Text('COMPLETE PROFILE')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  testWidgets('the completeness card renders the score and taps through to '
      '/complete-profile', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(completeness: {
      'score': 62,
      'intent_set': false,
      'sections': <dynamic>[],
      'next': <dynamic>[],
    })));
    await tester.pumpAndSettle();

    expect(find.byType(CompletenessRing), findsOneWidget);
    expect(find.text('Your profile is 62% complete'), findsOneWidget);

    await tester.tap(find.text('Your profile is 62% complete'));
    await tester.pumpAndSettle();

    expect(find.text('COMPLETE PROFILE'), findsOneWidget);
  });

  testWidgets('the card is hidden entirely on a fetch error', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(completenessStatus: 500)));
    await tester.pumpAndSettle();

    expect(find.byType(CompletenessRing), findsNothing);
    expect(find.textContaining('% complete'), findsNothing);
    // The rest of the Profile tab still renders.
    expect(find.text('My public profile'), findsOneWidget);
  });

  testWidgets('the card shows a done state via the complete flag',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Full current coverage caps at 95, never a literal 100 — `complete` is
    // the real "done for now" signal.
    await tester.pumpWidget(
      _host(_api(completeness: {'score': 95, 'complete': true})),
    );
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up ✓"), findsOneWidget);
  });

  testWidgets('the card shows a done state for a stale literal-100 score',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(completeness: {'score': 100})));
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up ✓"), findsOneWidget);
  });
}
