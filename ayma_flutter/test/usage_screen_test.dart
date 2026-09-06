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
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('58'), findsOneWidget);
    expect(find.textContaining('100 credits'), findsOneWidget);
    expect(find.text('FREE PLAN'), findsOneWidget);
    expect(find.text('42 spent'), findsOneWidget);
    expect(find.text('Reload credits'), findsOneWidget);
    expect(find.text('Tokens used so far'), findsOneWidget);
    expect(find.text('42k'), findsOneWidget); // lifetime token total
    expect(find.text('Text chat with Ayma'), findsOneWidget);
    expect(find.text('Match scoring'), findsOneWidget);
    // chat: 30,000 tokens ÷ 1,000 = 30 credits.
    expect(find.text('30 cr'), findsOneWidget);
  });

  testWidgets('reload calls topup and shows the new balance', (tester) async {
    var calls = 0;
    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/credits/topup') {
        calls++;
        return http.Response(
          jsonEncode({
            'total': 42000,
            'cap': 100000,
            'remaining': 58000,
            'features': {'chat': 42000},
            'credits': {'grant': 100, 'added': 100, 'used': 42,
                        'remaining': 158},
            'tokens_per_credit': 1000,
            'costs': {'match_score': 12},
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'total': 42000, 'cap': 100000, 'remaining': 58000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000, 'costs': {'match_score': 12},
        }),
        200,
      );
    });
    final api =
        ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('58'), findsOneWidget);
    await tester.tap(find.text('Reload credits'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('158'), findsOneWidget);
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
          'credits': {'grant': 100, 'added': 0, 'used': 100, 'remaining': 0},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
        }),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Out of credits'), findsOneWidget);
  });
}
