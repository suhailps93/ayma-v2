import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves one local fixture file for any URL, so grid photos (rendered
/// through [AymaPhoto] → [CachedNetworkImage]) run their real decode
/// pipeline with no sqflite cache database and no network.
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
    : file = const LocalFileSystem().file(ioFile.path);

  // flutter_cache_manager's API speaks package:file's File type.
  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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

  testWidgets('Explore grid renders the thumb variant URL (perf phase 2)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AymaPhoto.debugCacheManager =
        _FakeCacheManager(File('test/fixtures/tiny.png'));
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    final api = _api((_) => [
          {
            'uid': 'a',
            'name': 'Ash',
            'age': 29,
            'location': 'X',
            'photo_url': 'https://x/full.jpg',
            'photo_url_thumb': 'https://x/full__thumb_400.jpg',
          },
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    final urls = tester
        .widgetList<AymaPhoto>(find.byType(AymaPhoto))
        .map((w) => w.url)
        .toList();
    expect(urls, contains('https://x/full__thumb_400.jpg'));
    expect(urls, isNot(contains('https://x/full.jpg')));
  });

  testWidgets('Explore grid falls back to the original without a thumb',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AymaPhoto.debugCacheManager =
        _FakeCacheManager(File('test/fixtures/tiny.png'));
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    final api = _api((_) => [
          {
            'uid': 'a',
            'name': 'Ash',
            'age': 29,
            'location': 'X',
            'photo_url': 'https://x/full.jpg',
          },
        ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    final urls = tester
        .widgetList<AymaPhoto>(find.byType(AymaPhoto))
        .map((w) => w.url)
        .toList();
    expect(urls, contains('https://x/full.jpg'));
  });

  testWidgets('scrolling near the bottom appends the next page in place',
      (tester) async {
    ExploreScreenState.debugFlingVelocityThreshold = double.infinity;
    addTearDown(
        () => ExploreScreenState.debugFlingVelocityThreshold = 2500);

    final seenCursors = <String?>[];
    final api = _pagedApi(
      seenCursors: seenCursors,
      pages: (cursor) => cursor == null
          ? _cardMaps('P1', 10)
          : _cardMaps('P2', 5, age: 30),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('P1-0'), findsOneWidget);
    expect(find.text('P2-0'), findsNothing);

    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(seenCursors, contains('c2')); // page 2 was fetched by cursor
    await tester.scrollUntilVisible(find.text('P2-4'), 500,
        scrollable: find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(find.text('P2-4'), findsOneWidget); // appended, page 1 kept
    expect(seenCursors.where((c) => c == 'c2'), hasLength(1)); // fetched once
  });

  testWidgets('a failed next page keeps page 1 with a retry footer',
      (tester) async {
    ExploreScreenState.debugFlingVelocityThreshold = double.infinity;
    addTearDown(
        () => ExploreScreenState.debugFlingVelocityThreshold = 2500);

    final seenCursors = <String?>[];
    final failPage2 = [true]; // page-2 fetches fail until the retry tap
    final api = _pagedApi(
      seenCursors: seenCursors,
      failPage2: failPage2,
      pages: (cursor) => cursor == null
          ? _cardMaps('P1', 10)
          : _cardMaps('P2', 5, age: 30),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(seenCursors, contains('c2'));
    expect(find.text('P2-0'), findsNothing);
    await tester.scrollUntilVisible(
        find.text('Could not load more \u00b7 Tap to retry'), 500,
        scrollable: find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable)));
    expect(
        find.text('Could not load more \u00b7 Tap to retry'), findsOneWidget);

    failPage2[0] = false; // the retry succeeds
    await tester.tap(find.text('Could not load more \u00b7 Tap to retry'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('P2-4'), 500,
        scrollable: find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(find.text('P2-4'), findsOneWidget); // retry appended page 2
    await tester.scrollUntilVisible(find.text('P1-0'), -500,
        scrollable: find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(find.text('P1-0'), findsOneWidget); // page 1 retained throughout
  });

}

ApiClient _pagedApi({
  required List<Map<String, dynamic>> Function(String? cursor) pages,
  required List<String?> seenCursors,
  List<bool>? failPage2,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        final cursor = req.url.queryParameters['cursor'];
        seenCursors.add(cursor);
        if (cursor != null && (failPage2?.isNotEmpty ?? false) && failPage2!.first) {
          return http.Response('net down', 500);
        }
        final cards = pages(cursor);
        final last = cursor != null;
        return http.Response(
            jsonEncode({
              'cards': cards,
              if (!last) 'next_cursor': 'c2',
              'has_more': !last,
            }),
            200);
      }
      return http.Response('no', 404);
    }),
  );
}

List<Map<String, dynamic>> _cardMaps(String prefix, int n, {int age = 25}) => [
      for (var i = 0; i < n; i++)
        {'uid': '$prefix-$i', 'name': '$prefix-$i', 'age': age + i,
         'location': 'X'},
    ];

void _pinFlingOpen() {
  ExploreScreenState.debugFlingVelocityThreshold = double.infinity;
}

void _pagingTearDown() {
  ExploreScreenState.debugFlingVelocityThreshold = 2500;
}
