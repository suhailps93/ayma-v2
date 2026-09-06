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
  testWidgets('shows the credit balance, plan chip, and a credit breakdown',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'cap': 100000,
          'remaining': 58000,
          'features': {'chat': 30000, 'voice': 9000, 'matching': 3000},
          'credits': {'grant': 100, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12, 'run_matching': 5},
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('58'), findsOneWidget);
    expect(find.textContaining('100 credits'), findsOneWidget);
    expect(find.text('FREE PLAN'), findsOneWidget);
    expect(find.text('42 spent so far'), findsOneWidget);
    expect(find.text('Text chat with Ayma'), findsOneWidget);
    expect(find.text('Matchmaking'), findsOneWidget);
    // chat: 30,000 tokens ÷ 1,000 = 30 credits.
    expect(find.text('30 cr'), findsOneWidget);
  });

  testWidgets('at zero credits shows the out-of-credits message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 100000,
          'cap': 100000,
          'remaining': 0,
          'features': {'chat': 100000},
          'credits': {'grant': 100, 'used': 100, 'remaining': 0},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12, 'run_matching': 5},
        }),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Out of credits'), findsOneWidget);
  });
}
