import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(List<Map<String, dynamic>> Function(Uri uri) cards) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        return http.Response(jsonEncode({'cards': cards(req.url)}), 200);
      }
      if (req.url.path == '/explore/pass' || req.url.path == '/explore/like') {
        return http.Response(jsonEncode({'ok': true, 'mutual': false}), 200);
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
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('check compatibility'), findsOneWidget);

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
}
