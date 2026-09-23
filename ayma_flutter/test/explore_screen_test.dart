import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(
  List<Map<String, dynamic>> Function(Uri uri) cards, {
  void Function(String path)? onPost,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        return http.Response(jsonEncode({'cards': cards(req.url)}), 200);
      }
      if (req.method == 'POST') {
        onPost?.call(req.url.path);
        if (req.url.path == '/explore/like') {
          return http.Response(jsonEncode({'ok': true, 'mutual': false}), 200);
        }
        if (req.url.path == '/check-compatibility') {
          return http.Response(
              jsonEncode({'ok': true, 'score': 0.61, 'match_id': 'm'}), 200);
        }
      }
      return http.Response('no', 404);
    }),
  );
}

Widget _app(ApiClient api, {List<String>? pushed}) {
  final router = GoRouter(
    initialLocation: '/explore',
    routes: [
      GoRoute(
        path: '/explore',
        builder: (_, __) => ExploreScreen(apiClient: api),
      ),
      GoRoute(
        path: '/profile/user/:uid',
        builder: (_, s) {
          pushed?.add(s.pathParameters['uid']!);
          return const Scaffold(body: Text('PROFILE PAGE'));
        },
      ),
      GoRoute(
        path: '/dm/:threadId',
        builder: (_, __) => const Scaffold(body: Text('DM')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  testWidgets('opening Explore sets the voice screen-context (with the query)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(AppContext.instance.clear);

    AppContext.instance.clear();
    await tester.pumpWidget(_app(_api((_) => const [])));
    await tester.pumpAndSettle();

    expect(AppContext.instance.current.value.screen, 'explore');

    await tester.enterText(find.byType(TextField), 'climbers in Denver');
    await tester.pump();
    expect(AppContext.instance.current.value.screen, 'explore');
    expect(AppContext.instance.current.value.note, 'climbers in Denver');
  });

  testWidgets('runs a pending Explore search handed over by Ayma (voice)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => AppContext.instance.pendingExploreQuery = null);

    AppContext.instance.pendingExploreQuery = 'hiking in Austin';
    String? sentQuery;
    final api = _api((uri) {
      sentQuery = uri.queryParameters['q'];
      return const [];
    });

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('hiking in Austin'), findsOneWidget); // in the search box
    expect(sentQuery, 'hiking in Austin'); // and actually searched
    expect(AppContext.instance.pendingExploreQuery, isNull); // consumed once
  });

  testWidgets('renders the feed cards', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
          {'uid': 'b', 'name': 'Blake', 'age': 30, 'location': 'X',
           'score': 0.8},
        ]);

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Blake'), findsOneWidget);
    expect(find.text('80% match'), findsOneWidget);
  });

  testWidgets('cards have no inline actions — Like/Message/Match are on the '
      'profile now', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X'},
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('Message'), findsNothing);
    expect(find.text('Like'), findsNothing);
    expect(find.text('Match'), findsNothing);
  });

  testWidgets('the filter chips narrow the feed to your likes', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X',
           'liked': true},
          {'uid': 'b', 'name': 'Bo', 'age': 30, 'location': 'Y'},
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);

    await tester.tap(find.text('Your likes'));
    await tester.pumpAndSettle();

    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsNothing);
  });

  testWidgets(
      'tapping a selected filter chip again deselects it back to Everyone',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X',
           'mutual': true},
          {'uid': 'b', 'name': 'Bo', 'age': 30, 'location': 'Y',
           'liked': true},
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    ChoiceChip chipFor(String label) => tester.widget<ChoiceChip>(
        find.ancestor(
            of: find.text(label), matching: find.byType(ChoiceChip)));

    // Default: "Everyone" selected, both cards showing.
    expect(chipFor('Everyone').selected, isTrue);
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);

    // Tap "Mutual" — selects it and narrows the feed.
    await tester.tap(find.text('Mutual'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isTrue);
    expect(chipFor('Everyone').selected, isFalse);
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsNothing);

    // Tap "Mutual" again — deselects it, reverting to the Everyone default.
    await tester.tap(find.text('Mutual'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isFalse);
    expect(chipFor('Everyone').selected, isTrue);
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);

    // Re-select "Mutual", then tap a *different* chip directly — it should
    // switch cleanly without needing to deselect first.
    await tester.tap(find.text('Mutual'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isTrue);

    await tester.tap(find.text('Your likes'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isFalse);
    expect(chipFor('Your likes').selected, isTrue);
    expect(find.text('Ash'), findsNothing);
    expect(find.text('Bo'), findsOneWidget);
  });

  testWidgets('tapping the card body opens that user\'s profile',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pushed = <String>[];
    final api = _api((_) => [
          {'uid': 'ash-1', 'name': 'Ash', 'age': 29, 'location': 'X'},
        ]);
    await tester.pumpWidget(_app(api, pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ash'));
    await tester.pumpAndSettle();

    expect(pushed, ['ash-1']);
    expect(find.text('PROFILE PAGE'), findsOneWidget);
  });

  testWidgets(
      'reload() refetches the feed — how a returning tab visit picks up a '
      'just-recalculated match score without a rebuild or app restart',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var calls = 0;
    final api = _api((_) {
      calls++;
      return calls == 1
          ? [
              {'uid': 'dillu', 'name': 'Dillu', 'age': 29, 'location': 'X',
               'score': 0.43},
            ]
          : [
              {'uid': 'dillu', 'name': 'Dillu', 'age': 29, 'location': 'X',
               'score': 0.0},
            ];
    });

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(find.text('43% match'), findsOneWidget);
    expect(calls, 1);

    final state =
        tester.state<ExploreScreenState>(find.byType(ExploreScreen));
    await state.reload();
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('0% match'), findsOneWidget);
    expect(find.text('43% match'), findsNothing);
  });

  testWidgets('own card shows "This is you" and opens your own profile',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pushed = <String>[];
    final api = _api((_) => [
          {'uid': 'me', 'name': 'You', 'age': 31, 'location': 'X',
           'self': true},
        ]);
    await tester.pumpWidget(_app(api, pushed: pushed));
    await tester.pumpAndSettle();

    expect(find.text('This is you'), findsOneWidget);
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(pushed, ['me']);
  });
}
