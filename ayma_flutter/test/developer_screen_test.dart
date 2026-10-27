import 'dart:convert';

import 'package:ayma_flutter/screens/developer_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dev_panel_flag.dart';
import 'package:ayma_flutter/services/dev_panel_session.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_toast.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _usage({
  bool isDev = true,
  double sinceReset = 1.0784,
  double allTime = 2.5046,
  String? resetAt,
  List<Map<String, dynamic>> groups = const [],
  int remaining = 58,
}) => {
  'total': 42000,
  'features': {'chat': 42000},
  'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': remaining},
  'tokens_per_credit': 1000,
  'is_dev': isDev,
  if (isDev) ...{
    'real_money_since_reset_usd': sinceReset,
    'real_money_all_time_usd': allTime,
    'real_money_reset_at': resetAt,
    'spend_groups': groups,
  },
};

ApiClient _api(
  Future<http.Response> Function(http.Request req) handler,
) => ApiClient(
  httpClient: MockClient(handler),
  auth: MockFirebaseAuth(signedIn: true),
);

ApiClient _usageApi(Map<String, dynamic> body) =>
    _api((_) async => http.Response(jsonEncode(body), 200));

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AymaTheme.light, home: page));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    DevPanelFlag.instance.enabled.value = true;
    DevPanelSession.instance.lock();
  });
  tearDown(() => DevPanelSession.instance.lock());

  testWidgets('locked: shows only the password field, nothing sensitive', (
    tester,
  ) async {
    await _pump(
      tester,
      DeveloperScreen(
        auth: MockFirebaseAuth(signedIn: true),
        api: _usageApi(_usage()),
      ),
    );
    expect(find.byKey(const ValueKey('dev-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-unlock')), findsOneWidget);
    expect(find.text('BUILD'), findsNothing);
    expect(find.textContaining('spent for real'), findsNothing);
    expect(find.byKey(const ValueKey('dev-free-reload')), findsNothing);
    expect(find.byKey(const ValueKey('dev-panel-switch')), findsNothing);
    expect(find.byKey(const ValueKey('dev-release-notes')), findsNothing);
  });

  testWidgets('correct password unlocks and shows the contents', (
    tester,
  ) async {
    var verified = false;
    final api = _api((req) async {
      if (req.url.path == '/dev/verify') {
        verified = true;
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      return http.Response(
        jsonEncode(
          _usage(
            groups: [
              {
                'id': 'room-1',
                'kind': 'voice',
                'day': '2026-09-26',
                'last_ts': '2026-09-26T10:06:00+00:00',
                'events': 6,
                'cost_usd': 1.06,
                'features': {'voice': 1.06},
              },
            ],
          ),
        ),
        200,
      );
    });
    await _pump(
      tester,
      DeveloperScreen(
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
        api: api,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('dev-password')), 'pw');
    await tester.tap(find.byKey(const ValueKey('dev-unlock')));
    await tester.pumpAndSettle();

    expect(verified, isTrue);
    expect(DevPanelSession.instance.unlocked.value, isTrue);
    expect(find.text('BUILD'), findsOneWidget);
    expect(find.text('u1'), findsOneWidget);
    expect(find.text('\$1.08'), findsOneWidget);
    expect(find.text('Voice call · 6 turns'), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-free-reload')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-panel-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-release-notes')), findsOneWidget);
  });

  testWidgets('wrong password stays locked and is explained; lockout too', (
    tester,
  ) async {
    var status = 403;
    final api = _api((req) async {
      if (req.url.path == '/dev/verify') {
        return http.Response('{"detail":"x"}', status);
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.enterText(find.byKey(const ValueKey('dev-password')), 'bad');
    await tester.tap(find.byKey(const ValueKey('dev-unlock')));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password.'), findsOneWidget);
    expect(DevPanelSession.instance.unlocked.value, isFalse);
    expect(find.byKey(const ValueKey('dev-password')), findsOneWidget);
    expect(find.text('BUILD'), findsNothing);

    status = 429;
    AymaToast.hide();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dev-password')), 'bad');
    await tester.tap(find.byKey(const ValueKey('dev-unlock')));
    await tester.pumpAndSettle();
    expect(
      find.text('Too many wrong passwords. Try again later.'),
      findsOneWidget,
    );
    expect(DevPanelSession.instance.unlocked.value, isFalse);
  });

  testWidgets('unlocked: accounts off the dev allowlist get no dollar figures',
      (tester) async {
    DevPanelSession.instance.unlock('pw');
    await _pump(
      tester,
      DeveloperScreen(
        auth: MockFirebaseAuth(signedIn: true),
        api: _usageApi(_usage(isDev: false)),
      ),
    );
    expect(find.byKey(const ValueKey('dev-spend-unavailable')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-free-reload')), findsNothing);
    expect(find.textContaining('spent for real'), findsNothing);
  });

  testWidgets('the AI-notes toggle sends the stored password to the server', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    final posts = <Map<String, dynamic>>[];
    final api = _api((req) async {
      if (req.method == 'POST' && req.url.path == '/dev/flags') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posts.add(body);
        return http.Response(jsonEncode({'dev_panel': body['dev_panel']}), 200);
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-panel-switch')));
    await tester.pumpAndSettle();
    expect(posts, [
      {'password': 'pw', 'dev_panel': false},
    ]);
    expect(DevPanelFlag.instance.enabled.value, isFalse);
  });

  testWidgets(
      'AI-notes toggle: a write that does not take fails visibly, switch stays',
      (tester) async {
    DevPanelSession.instance.unlock('pw');
    DevPanelFlag.instance.enabled.value = true;
    // Server answers 200 but the flag is UNCHANGED (write never landed).
    final api = _api((req) async {
      if (req.method == 'POST' && req.url.path == '/dev/flags') {
        return http.Response(jsonEncode({'dev_panel': true}), 200);
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-panel-switch')));
    await tester.pumpAndSettle();
    // Visible error, and the flag reflects the true (unchanged) state.
    expect(find.textContaining("Couldn't save that"), findsOneWidget);
    expect(DevPanelFlag.instance.enabled.value, isTrue);
  });

  testWidgets('AI-notes toggle: a server error fails visibly, switch stays', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    DevPanelFlag.instance.enabled.value = true;
    final api = _api((req) async {
      if (req.method == 'POST' && req.url.path == '/dev/flags') {
        return http.Response('{"detail":"boom"}', 500);
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-panel-switch')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't switch the flag"), findsOneWidget);
    expect(DevPanelFlag.instance.enabled.value, isTrue);
  });

  testWidgets('free reload calls topup and shows the new balance', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    var topups = 0;
    final api = _api((req) async {
      if (req.method == 'POST' && req.url.path == '/credits/topup') {
        topups++;
        return http.Response(jsonEncode(_usage(remaining: 158)), 200);
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-free-reload')));
    await tester.pumpAndSettle();
    expect(topups, 1);
    expect(find.text('Credits reloaded — 158 left.'), findsOneWidget);
  });

  testWidgets('reload answered upgrade-required shows the upgrade dialog', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    final api = _api((req) async {
      if (req.url.path == '/credits/topup') {
        return http.Response(
          jsonEncode({
            'detail': {
              'error': 'upgrade_required',
              'message': 'Upgrade your plan to keep going.',
            },
          }),
          402,
        );
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-free-reload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('upgrade-dialog')), findsOneWidget);
  });

  testWidgets('reset confirms, then shows the refreshed tracker', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    var resets = 0;
    final api = _api((req) async {
      if (req.url.path == '/usage/reset-real-money') {
        resets++;
        return http.Response(
          jsonEncode(
            _usage(
              sinceReset: 0,
              allTime: 1.08,
              resetAt: '2026-09-26T11:00:00+00:00',
            ),
          ),
          200,
        );
      }
      return http.Response(
        jsonEncode(_usage(sinceReset: 1.08, allTime: 1.08)),
        200,
      );
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    expect(find.text('\$1.08'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('reset-money-tracker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resets, 0);

    await tester.tap(find.byKey(const ValueKey('reset-money-tracker')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(resets, 1);
    expect(find.text('\$0.00'), findsOneWidget);
    expect(find.text('Since your reset on Sep 26.'), findsOneWidget);
  });
}
