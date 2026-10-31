import 'dart:convert';

import 'package:ayma_flutter/screens/developer_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dev_panel_session.dart';
import 'package:ayma_flutter/services/tour_request.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_toast.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    SharedPreferences.setMockInitialValues({});
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
    expect(find.byKey(const ValueKey('dev-release-notes')), findsNothing);
    // The dev-only "Ayma's notes" entry is gated behind the unlock too — a
    // locked panel never exposes the analysis layer's entry point.
    expect(find.byKey(const ValueKey('dev-ayma-notes')), findsNothing);
    expect(find.byKey(const ValueKey('dev-test-upgrade-pro')), findsNothing);
  });

  testWidgets("unlocked: the Ayma's notes entry opens the dev-only notes page",
      (tester) async {
    DevPanelSession.instance.unlock('pw');
    final api = _usageApi(_usage());
    final router = GoRouter(
      initialLocation: '/dev',
      routes: [
        GoRoute(
          path: '/dev',
          builder: (_, __) => DeveloperScreen(
            auth: MockFirebaseAuth(signedIn: true),
            api: api,
          ),
        ),
        // The real route is dev-gated in `app_router.dart`; here a sentinel
        // proves the entry pushes exactly AymaNotesScreen.path.
        GoRoute(
          path: AymaNotesScreen.path,
          builder: (_, __) => const Scaffold(body: Text('AYMA NOTES PAGE')),
        ),
      ],
    );
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router, theme: AymaTheme.light),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('dev-ayma-notes'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('AYMA NOTES PAGE'), findsOneWidget);
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
    // The voice-stack control moved to user-facing Ayma settings; the dev panel
    // no longer carries it.
    expect(find.text('Voice engine'), findsNothing);
    expect(find.byKey(const ValueKey('voice-engine-control')), findsNothing);
    expect(find.byKey(const ValueKey('dev-free-reload')), findsOneWidget);
    // The AI-notes flag toggle was retired (dev AI notes are now dev-only in
    // the password-gated Ayma's-notes screen); its switch no longer exists.
    expect(find.byKey(const ValueKey('dev-panel-switch')), findsNothing);
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
    expect(find.byKey(const ValueKey('dev-test-upgrade-pro')), findsNothing);
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

  testWidgets('unlocked + dev view: all three test-upgrade tiers show', (
    tester,
  ) async {
    DevPanelSession.instance.unlock('pw');
    await _pump(
      tester,
      DeveloperScreen(
        auth: MockFirebaseAuth(signedIn: true),
        api: _usageApi(_usage()),
      ),
    );
    expect(find.byKey(const ValueKey('dev-test-upgrade-plus')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-test-upgrade-pro')), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-test-upgrade-max')), findsOneWidget);
  });

  testWidgets('tapping a tier calls /dev/test-upgrade and refreshes the balance',
      (tester) async {
    DevPanelSession.instance.unlock('pw');
    final posts = <Map<String, dynamic>>[];
    final api = _api((req) async {
      if (req.method == 'POST' && req.url.path == '/dev/test-upgrade') {
        posts.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({..._usage(remaining: 1400), 'plan': 'pro'}),
          200,
        );
      }
      return http.Response(jsonEncode(_usage()), 200);
    });
    await _pump(
      tester,
      DeveloperScreen(auth: MockFirebaseAuth(signedIn: true), api: api),
    );
    await tester.tap(find.byKey(const ValueKey('dev-test-upgrade-pro')));
    await tester.pumpAndSettle();
    expect(posts, [
      {'plan': 'pro'},
    ]);
    expect(
      find.textContaining('Test upgrade: pro plan — 1400 credits'),
      findsOneWidget,
    );
  });

  testWidgets('reset & preview feature tour returns to the shell and requests '
      'the full tour', (tester) async {
    DevPanelSession.instance.unlock('pw');
    TourRequest.instance.consume(); // start clean
    addTearDown(() => TourRequest.instance.consume());
    // The interactive coach-mark tour runs over the live shell, so the dev tile
    // no longer pushes a tour screen — it sets a TourRequest and go('/')s back
    // to the shell, whose gate consumes it. The seen-state reset() is a
    // best-effort Firestore clear that no-ops without Firebase here.
    final router = GoRouter(
      initialLocation: DeveloperScreen.path,
      routes: [
        GoRoute(
          path: DeveloperScreen.path,
          builder: (_, __) => DeveloperScreen(
            auth: MockFirebaseAuth(signedIn: true),
            api: _usageApi(_usage()),
          ),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('screen:shell')),
        ),
      ],
    );
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(theme: AymaTheme.light, routerConfig: router),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('dev-reset-feature-tour')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dev-reset-feature-tour')));
    await tester.pumpAndSettle();

    // Navigated back to the shell with a pending full-tour request for its gate.
    expect(find.text('screen:shell'), findsOneWidget);
    expect(TourRequest.instance.pending.value, isTrue);
  });
}
