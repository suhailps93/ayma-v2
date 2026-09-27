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
  testWidgets('shows the credit balance, plan chip, and a credit breakdown '
      '— credits only, never raw tokens or a dollar figure', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'features': {'chat': 30000, 'voice': 9000, 'matching': 3000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          'cost_usd': 3.4567,
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('58'), findsOneWidget);
    expect(find.textContaining('credits left'), findsOneWidget);
    expect(find.text('FREE PLAN'), findsOneWidget);
    expect(find.text('42 spent so far'), findsOneWidget);
    expect(find.text('Reload credits'), findsOneWidget);
    expect(find.text('Text chat with Ayma'), findsOneWidget);
    expect(find.text('Match scoring'), findsOneWidget);
    // chat: 30,000 tokens ÷ 1,000 = 30 credits.
    expect(find.text('30 cr'), findsOneWidget);
    // § founder: this screen shows credits and their usage only — never the
    // raw token count or a dollar figure (that's the admin dashboard's job).
    expect(find.text('Tokens used so far'), findsNothing);
    expect(find.textContaining('tok'), findsNothing);
    expect(find.text('Actual cost to run this'), findsNothing);
    expect(find.textContaining('\$'), findsNothing);
  });

  testWidgets('reload calls topup and shows the new balance', (tester) async {
    var calls = 0;
    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/credits/topup') {
        calls++;
        return http.Response(
          jsonEncode({
            'total': 42000,
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
          'total': 42000,
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

  testWidgets('has a Credits / Real money tab switch rendering both views',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          'real_money_usd': 0.0,
          'spend_groups': [],
        }),
      ),
    ));
    await tester.pumpAndSettle();

    // Credits view is the default.
    expect(find.text('Real money'), findsOneWidget);
    expect(find.textContaining('credits left'), findsOneWidget);
    expect(find.textContaining('spent for real'), findsNothing);

    await tester.tap(find.text('Real money'));
    await tester.pumpAndSettle();
    expect(find.textContaining('spent for real'), findsOneWidget);
    expect(find.textContaining('credits left'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('spend-tab-credits')));
    await tester.pumpAndSettle();
    expect(find.textContaining('credits left'), findsOneWidget);
  });

  testWidgets('Real money tab starts from \$0.00 with an empty list',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          // Lifetime cost history exists, but real-money tracking starts NOW
          // at zero — the tab must show $0.00, never a retro-estimate.
          'cost_usd': 3.4567,
          'real_money_usd': 0.0,
          'spend_groups': [],
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Real money'));
    await tester.pumpAndSettle();

    // Both figures — "since last reset" (the big header) and "all time" —
    // start at $0.00 together.
    expect(find.text('\$0.00'), findsNWidgets(2));
    expect(find.text('  all time'), findsOneWidget);
    // Never reset: the tracking-began sub-line, not a reset date.
    expect(find.textContaining('Since money tracking began'), findsOneWidget);
    expect(find.textContaining('Since your reset'), findsNothing);
    expect(find.text('Nothing spent yet.'), findsOneWidget);
    // The lifetime cost figure must not leak in as the header.
    expect(find.textContaining('3.45'), findsNothing);
    // The honest footer: these tokens are billed, not free.
    expect(find.textContaining('not free'), findsOneWidget);
  });

  testWidgets(
      'Real money tab lists one row per conversation with dollar costs '
      '— cents for real amounts, sub-cent precision for tiny ones',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          'real_money_usd': 1.0784,
          'real_money_since_reset_usd': 1.0784,
          'real_money_all_time_usd': 2.5046,
          'real_money_reset_at': null,
          'spend_groups': [
            {
              'id': 'room-1', 'kind': 'voice', 'session_id': 'room-1',
              'day': '2026-09-26',
              'first_ts': '2026-09-26T10:00:00+00:00',
              'last_ts': '2026-09-26T10:06:00+00:00',
              'events': 6, 'cost_usd': 1.06,
              'features': {'voice': 1.06},
            },
            {
              'id': 's-77', 'kind': 'chat', 'session_id': 's-77',
              'day': '2026-09-25',
              'first_ts': '2026-09-25T08:00:00+00:00',
              'last_ts': '2026-09-25T08:04:00+00:00',
              'events': 2, 'cost_usd': 0.0154,
              'features': {'chat': 0.012, 'wiki': 0.0034},
            },
            {
              'id': 'day:2026-09-24', 'kind': 'background',
              'session_id': '', 'day': '2026-09-24',
              'first_ts': '2026-09-24T02:00:00+00:00',
              'last_ts': '2026-09-24T02:00:00+00:00',
              'events': 1, 'cost_usd': 0.003,
              'features': {'wiki': 0.003},
            },
          ],
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Real money'));
    await tester.pumpAndSettle();

    // Header: the since-reset figure, to the cent — with the all-time
    // figure alongside it.
    expect(find.text('\$1.08'), findsOneWidget);
    expect(find.text('\$2.50'), findsOneWidget);
    // One row per conversation, saying what it was.
    expect(find.text('Voice call · 6 turns'), findsOneWidget);
    expect(find.text('Chat with Ayma'), findsOneWidget);
    expect(find.text('Wiki update'), findsOneWidget);
    // Row costs: cents for real amounts, sub-cent for tiny ones.
    expect(find.text('\$1.06'), findsOneWidget);
    expect(find.text('\$0.0154'), findsOneWidget);
    expect(find.text('\$0.0030'), findsOneWidget);
  });

  testWidgets(
      'after a reset the header splits: big since-reset figure with the '
      'reset date, smaller all-time figure', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 42000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          'real_money_usd': 0.0154,
          'real_money_since_reset_usd': 0.0154,
          'real_money_all_time_usd': 1.08,
          'real_money_reset_at': '2026-09-20T10:00:00+00:00',
          'spend_groups': [],
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Real money'));
    await tester.pumpAndSettle();

    // Big figure = since the reset; small figure = all time, untouched.
    expect(find.text('\$0.0154'), findsOneWidget);
    expect(find.text('\$1.08'), findsOneWidget);
    expect(find.text('  all time'), findsOneWidget);
    // The sub-line names the reset date instead of the tracking-began line.
    expect(find.text('Since your reset on Sep 20.'), findsOneWidget);
    expect(find.textContaining('Since money tracking began'), findsNothing);
  });

  testWidgets(
      'Reset asks for confirmation, calls the reset endpoint, and shows the '
      'refreshed figures — Cancel calls nothing', (tester) async {
    var resets = 0;
    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/usage/reset-real-money') {
        resets++;
        return http.Response(
          jsonEncode({
            'total': 42000,
            'features': {'chat': 42000},
            'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
            'tokens_per_credit': 1000,
            'costs': {'match_score': 12},
            'real_money_usd': 0.0,
            'real_money_since_reset_usd': 0.0,
            'real_money_all_time_usd': 1.08,
            'real_money_reset_at': '2026-09-26T11:00:00+00:00',
            'spend_groups': [],
          }),
          200,
        );
      }
      expect(req.url.path, '/usage');
      return http.Response(
        jsonEncode({
          'total': 42000,
          'features': {'chat': 42000},
          'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
          'tokens_per_credit': 1000,
          'costs': {'match_score': 12},
          'real_money_usd': 1.08,
          'real_money_since_reset_usd': 1.08,
          'real_money_all_time_usd': 1.08,
          'real_money_reset_at': null,
          'spend_groups': [],
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
    await tester.tap(find.text('Real money'));
    await tester.pumpAndSettle();

    // Since-reset and all-time both read $1.08 before the reset.
    expect(find.text('\$1.08'), findsNWidgets(2));

    // Cancel first: no API call, figures unchanged.
    await tester.tap(find.byKey(const ValueKey('reset-money-tracker')));
    await tester.pumpAndSettle();
    expect(find.text('Reset the money tracker?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resets, 0);
    expect(find.text('\$1.08'), findsNWidgets(2));

    // Confirm: the endpoint is hit and the refreshed view lands — tracker
    // at $0.00, all-time still $1.08, the reset date on the sub-line.
    await tester.tap(find.byKey(const ValueKey('reset-money-tracker')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();

    expect(resets, 1);
    expect(find.text('\$0.00'), findsOneWidget);
    expect(find.text('\$1.08'), findsOneWidget);
    expect(find.text('Since your reset on Sep 26.'), findsOneWidget);
  });

  testWidgets('at zero credits shows the out-of-credits message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: UsageScreen(
        api: _api({
          'total': 100000,
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
