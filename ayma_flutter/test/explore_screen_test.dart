import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(
  List<Map<String, dynamic>> Function(Uri uri) cards, {
  void Function(String path)? onPost,
  String? Function(Uri uri)? nextCursor,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        return http.Response(
            jsonEncode({
              'candidates': cards(req.url),
              'next_cursor': nextCursor?.call(req.url),
            }),
            200);
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
      'sub-filter chips toggle over the feed while the mode stays Everyone',
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

    // Default: the "Everyone" mode is selected, no sub-filter, both cards show.
    expect(chipFor('Everyone').selected, isTrue);
    expect(chipFor('Potential matches').selected, isFalse);
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);

    // Tap "Mutual" — narrows the feed client-side; the mode stays Everyone.
    await tester.tap(find.text('Mutual'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isTrue);
    expect(chipFor('Everyone').selected, isTrue); // mode is independent
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsNothing);

    // Tap "Mutual" again — clears the sub-filter, whole feed back.
    await tester.tap(find.text('Mutual'));
    await tester.pumpAndSettle();
    expect(chipFor('Mutual').selected, isFalse);
    expect(find.text('Ash'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);

    // Re-select "Mutual", then tap a *different* sub-filter — switches cleanly.
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

  testWidgets('the first page loads with mode=everyone and limit=20',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final requests = <Uri>[];
    final api = _api((uri) {
      requests.add(uri);
      return const [];
    });
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(requests, isNotEmpty);
    expect(requests.first.queryParameters['mode'], 'everyone');
    expect(requests.first.queryParameters['limit'], '20');
    expect(requests.first.queryParameters.containsKey('cursor'), isFalse);
  });

  testWidgets('tapping "Potential matches" refetches with mode=matches',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final requests = <Uri>[];
    final api = _api((uri) {
      requests.add(uri);
      return const [];
    });
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['mode'], 'everyone');

    await tester.tap(find.text('Potential matches'));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['mode'], 'matches');
    final chip = tester.widget<ChoiceChip>(find.ancestor(
        of: find.text('Potential matches'), matching: find.byType(ChoiceChip)));
    expect(chip.selected, isTrue);
  });

  testWidgets(
      'scrolling to the bottom fetches the next page with the cursor and '
      'appends it', (tester) async {
    // A short viewport so the first page overflows and the grid can scroll.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final requests = <Uri>[];
    final api = _api(
      (uri) {
        requests.add(uri);
        final cursor = uri.queryParameters['cursor'];
        if (cursor == null) {
          // Page 1: a full page of "A" people.
          return [
            for (var i = 0; i < 12; i++)
              {'uid': 'a$i', 'name': 'Alpha$i', 'age': 25, 'location': 'X'},
          ];
        }
        // Page 2 (cursor sent): the "B" people, no further pages.
        return [
          for (var i = 0; i < 6; i++)
            {'uid': 'b$i', 'name': 'Beta$i', 'age': 26, 'location': 'Y'},
        ];
      },
      // Page 1 advertises a next page; page 2 is the last.
      nextCursor: (uri) =>
          uri.queryParameters['cursor'] == null ? 'cursor-2' : null,
    );

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(requests.length, 1);
    expect(find.text('Alpha0'), findsOneWidget);
    expect(find.text('Beta0'), findsNothing);

    // Drag the grid to the bottom — fires the infinite-scroll fetch.
    await tester.drag(
        find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pumpAndSettle();

    expect(requests.length, 2);
    expect(requests.last.queryParameters['cursor'], 'cursor-2');
    expect(requests.last.queryParameters['mode'], 'everyone');

    // The second page is appended, not replacing the first: scroll down to the
    // freshly-appended rows and the first page's people are still reachable.
    await tester.drag(
        find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(find.text('Beta5'), findsOneWidget);
    // No third fetch — page 2 was the last (next_cursor was null).
    expect(requests.length, 2);
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

  testWidgets('after a search loads, Explore mirrors the visible people into '
      'the screen context and publishes an Explore report', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(AppContext.instance.clear);
    addTearDown(() => AppContext.instance.pendingExploreQuery = null);

    AppContext.instance.pendingExploreQuery = 'hiking';
    final reports = <ExploreReport>[];
    void listener() => reports.add(AppContext.instance.exploreReport.value!);
    AppContext.instance.exploreReport.addListener(listener);
    addTearDown(() => AppContext.instance.exploreReport.removeListener(listener));

    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'Austin'},
          {'uid': 'b', 'name': 'Blake', 'age': 30, 'location': 'Dallas',
           'score': 0.8},
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    final detail = AppContext.instance.current.value.detail;
    expect(detail, contains('Search "hiking"'));
    expect(detail, contains('2 people'));
    expect(detail, contains('Ash, 29, Austin'));
    expect(detail, contains('Blake, 30, Dallas, 80% match'));
    expect(reports.last.query, 'hiking');
    expect(reports.last.summary, detail);
  });

  test('exploreSummary caps the people listed and the total length', () {
    final cards = [
      for (var i = 0; i < 40; i++)
        ExploreCard(
          uid: 'u$i',
          name: 'Person${'x' * 80}$i',
          age: 30,
          location: 'City',
        ),
    ];
    final out = exploreSummary(
        query: 'q', filterLabel: 'Everyone', cards: cards);
    expect(out.length, lessThanOrEqualTo(1200));
    expect(out, contains('40 people'));
    expect(
        exploreSummary(query: '', filterLabel: 'Mutual', cards: const []),
        'No search text, filter "Mutual": nobody is listed.');
  });

  testWidgets('Ayma picks an Explore filter chip through ui_action',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    final api = _api((_) => [
          {'uid': 'a', 'name': 'Ash', 'age': 29, 'location': 'X',
           'liked': true},
          {'uid': 'b', 'name': 'Bo', 'age': 30, 'location': 'Y'},
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final cap = ScreenCapture(
      routeOf: () => '/explore',
      popupOpen: () => false,
      settle: () => tester.pumpAndSettle(),
    );
    final s = cap.capture();
    expect(s.visible, contains('Ash'));
    final chip = s.controls.firstWhere((c) => c.label.contains('Your likes'));
    final r = await cap.perform(control: chip.id, label: chip.label, op: 'tap');
    expect(r.ok, isTrue, reason: r.reason);
    expect(find.text('Bo'), findsNothing);
    expect(r.result, isNot(contains('Bo')));
    handle.dispose();
  });
}
