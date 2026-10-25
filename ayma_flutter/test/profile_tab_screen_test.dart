import 'dart:convert';

import 'package:ayma_flutter/screens/profile_tab_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/credits_balance.dart';
import 'package:ayma_flutter/services/meta_integrations.dart';
import 'package:ayma_flutter/widgets/completeness_ring.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api({
  Map<String, dynamic>? completeness,
  int completenessStatus = 200,
  int? creditsRemaining,
  String? deepDiveReportId,
  bool appearanceReport = false,
}) {
  final mockHttp = MockClient((req) async {
    if (req.url.path == '/completeness') {
      return http.Response(
        jsonEncode(completeness ?? const {}),
        completenessStatus,
        headers: _jsonUtf8,
      );
    }
    if (req.url.path == '/deep-dive/mine') {
      return http.Response(
        jsonEncode(deepDiveReportId == null
            ? {'exists': false}
            : {
                'exists': true,
                'report_id': deepDiveReportId,
                'summary': 's',
                'confidence': 'high',
              }),
        200,
        headers: _jsonUtf8,
      );
    }
    if (req.url.path == '/appearance/history') {
      return http.Response(
        jsonEncode({
          'reports': appearanceReport
              ? [
                  {'id': 'a1'}
                ]
              : <dynamic>[],
        }),
        200,
        headers: _jsonUtf8,
      );
    }
    if (req.url.path == '/usage' && creditsRemaining != null) {
      return http.Response(
        jsonEncode({
          'credits': {'remaining': creditsRemaining},
        }),
        200,
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
      for (final path in const [
        '/settings',
        '/settings/ayma',
        '/skills',
        '/appearance/current',
        '/deep-dive/rep1',
        '/profile/plan',
      ])
        GoRoute(
          path: path,
          builder: (_, __) => Scaffold(body: Text('ROUTE $path')),
        ),
      GoRoute(
        path: '/invite-friends',
        builder: (_, __) => const Scaffold(body: Text('INVITE FRIENDS')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUp(() => CreditsBalance.instance.remaining.value = null);
  tearDown(() => MetaIntegrations.enabled.value = false);

  test('the meta flag only turns on for a literal enabled:true', () {
    expect(MetaIntegrations.parse(null), isFalse);
    expect(MetaIntegrations.parse({'enabled': 'true'}), isFalse);
    expect(MetaIntegrations.parse({'enabled': true}), isTrue);
  });

  testWidgets('meta_integrations off hides the Connect Instagram row',
      (tester) async {
    MetaIntegrations.enabled.value = false;
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();
    expect(find.text('Connect Instagram', skipOffstage: false), findsNothing);
  });

  testWidgets('meta_integrations on shows the Connect Instagram row',
      (tester) async {
    MetaIntegrations.enabled.value = true;
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();
    expect(
        find.text('Connect Instagram', skipOffstage: false), findsOneWidget);
  });

  testWidgets('the Invite friends row renders and taps through',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    expect(find.text('Invite friends'), findsOneWidget);
    await tester.tap(find.text('Invite friends'));
    await tester.pumpAndSettle();

    expect(find.text('INVITE FRIENDS'), findsOneWidget);
  });

  testWidgets('menu has You then Ayma sections in the requested order',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    final order = [
      'YOU',
      'My public profile',
      'My story',
      'Profile details',
      'Search the web about me',
      'Appearance',
      'User settings',
      'AYMA',
      'Ayma’s settings',
      'Plan',
    ];
    final ys = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    expect([...ys]..sort(), ys, reason: 'rows must appear in this order');
    expect(find.text('Face verified'), findsNothing);
    expect(find.text('Pause matching'), findsNothing);
  });

  testWidgets('User settings, Ayma\'s settings and Plan tap through',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final entry in const {
      'User settings': '/settings',
      'Ayma’s settings': '/settings/ayma',
      'Plan': '/profile/plan',
    }.entries) {
      await tester.pumpWidget(_host(_api()));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(find.text('ROUTE ${entry.value}'), findsOneWidget, reason: entry.key);
    }
  });

  testWidgets('web research opens the last report when one exists',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(deepDiveReportId: 'rep1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search the web about me'));
    await tester.pumpAndSettle();

    expect(find.text('ROUTE /deep-dive/rep1'), findsOneWidget);
  });

  testWidgets('web research opens the run screen when there is no report',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search the web about me'));
    await tester.pumpAndSettle();

    expect(find.text('ROUTE /skills'), findsOneWidget);
  });

  testWidgets('Appearance opens the last report when one exists',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(appearanceReport: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(find.text('ROUTE /appearance/current'), findsOneWidget);
  });

  testWidgets('Appearance opens the run screen when there is no report',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(find.text('ROUTE /skills'), findsOneWidget);
  });

  testWidgets('the credits row shows the fetched balance', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(creditsRemaining: 83)));
    await tester.pumpAndSettle();

    expect(find.text('83'), findsOneWidget);
  });

  testWidgets(
      'the credits row updates when another screen refreshes the shared '
      'balance, even without rebuilding itself (§ founder: real balance 83, '
      'row stuck on 0)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(creditsRemaining: 0)));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);

    // Simulates the Plan screen fetching a fresh balance elsewhere (a reload, a
    // pull-to-refresh) — the tab row must pick it up live, not stay on the
    // number it fetched once at its own initState.
    CreditsBalance.instance.remaining.value = 83;
    await tester.pump();

    expect(find.text('83'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

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
