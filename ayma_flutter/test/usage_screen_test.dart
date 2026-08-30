import 'dart:convert';

import 'package:ayma_flutter/screens/usage_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

ApiClient _api(Map<String, dynamic> body) {
  final mock = MockClient((req) async {
    expect(req.url.path, '/usage');
    return http.Response(jsonEncode(body), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('shows total vs cap, remaining, and a sorted breakdown',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'cap': 100000,
          'remaining': 58000,
          'features': {'chat': 30000, 'voice': 9000, 'matching': 3000},
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('42k of 100k tokens'), findsOneWidget);
    expect(find.text('58k left'), findsOneWidget);
    expect(find.text('Text chat with Ayma'), findsOneWidget);
    expect(find.text('Voice with Ayma'), findsOneWidget);
    expect(find.text('Matchmaking'), findsOneWidget);
  });

  testWidgets('at the cap shows the limit-reached message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 100000,
          'cap': 100000,
          'remaining': 0,
          'features': {'chat': 100000},
        }),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('reached the limit'), findsOneWidget);
  });
}
