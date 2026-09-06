import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(
  List<Map<String, dynamic>> Function(Uri uri) cards, {
  int creditsRemaining = 100,
  int matchCost = 12,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        return http.Response(jsonEncode({'cards': cards(req.url)}), 200);
      }
      if (req.url.path == '/explore/pass' || req.url.path == '/explore/like') {
        return http.Response(jsonEncode({'ok': true, 'mutual': false}), 200);
      }
      if (req.url.path == '/usage') {
        return http.Response(
          jsonEncode({
            'total': 0,
            'cap': 100000,
            'remaining': 100000,
            'features': const {},
            'credits': {
              'grant': 100,
              'used': 100 - creditsRemaining,
              'remaining': creditsRemaining,
            },
            'tokens_per_credit': 1000,
            'costs': {'match_score': matchCost, 'run_matching': 5},
          }),
          200,
        );
      }
      if (req.url.path == '/check-compatibility') {
        return http.Response(
          jsonEncode({'ok': true, 'match_id': 'x__y', 'score': 0.42}),
          200,
        );
      }
      return http.Response('no', 404);
    }),
  );
}

void main() {
  testWidgets('renders cards and narrows on the hair filter', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((uri) {
      final hair = uri.queryParameters['hair_color'];
      if (hair == 'blonde') {
        return [
          {'uid': 'b', 'name': 'Blake', 'age': 30, 'location': 'X', 'score': 0.8}
        ];
      }
      return [
        {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
        {'uid': 'b', 'name': 'Blake', 'age': 30, 'location': 'X', 'score': 0.8},
      ];
    });

    await tester.pumpWidget(MaterialApp(home: ExploreScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Blake'), findsOneWidget);
    expect(find.text('80% match'), findsOneWidget);
    // Ash has no score yet — the credit-priced "Calculate match" button shows.
    expect(find.text('Calculate match'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'blonde'));
    await tester.pumpAndSettle();

    expect(find.text('Ash'), findsNothing);
    expect(find.text('Blake'), findsOneWidget);

    // pass removes the card from the list
    await tester.tap(find.widgetWithText(OutlinedButton, 'Pass'));
    await tester.pumpAndSettle();
    expect(find.text('Blake'), findsNothing);
  });

  testWidgets('own card shows "This is you" with no Like/Pass', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'me', 'name': 'You', 'age': 31, 'location': 'X',
           'self': true},
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
        ]);
    await tester.pumpWidget(MaterialApp(home: ExploreScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('You'), findsOneWidget);
    expect(find.text('This is you'), findsOneWidget);
    // Only Ash's card carries the actions.
    expect(find.widgetWithText(OutlinedButton, 'Pass'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Like'), findsOneWidget);
  });

  testWidgets('Calculate match spends credits and shows the score',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
        ]);
    await tester.pumpWidget(MaterialApp(home: ExploreScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Calculate match'), findsOneWidget);
    await tester.tap(find.text('Calculate match'));
    await tester.pumpAndSettle();

    expect(find.text('42% match'), findsOneWidget);
    expect(find.text('Calculate match'), findsNothing);
  });

  testWidgets('Calculate match is disabled when credits are short',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api(
      (_) => [
        {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
      ],
      creditsRemaining: 5,
      matchCost: 12,
    );
    await tester.pumpWidget(MaterialApp(home: ExploreScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Need 12 credits'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Calculate match'),
    );
    expect(btn.onPressed, isNull);
  });
}
