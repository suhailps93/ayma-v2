import 'dart:convert';

import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _profile({
  bool self = false,
  bool liked = false,
  double? score,
  Map<String, dynamic>? physicalAttributes,
  List<Map<String, dynamic>> pages = const [
    {'page_type': 'identity', 'title': '', 'body': 'From Lisbon, lives in Berlin.'},
    {'page_type': 'interests', 'title': '', 'body': 'Climbs and cooks.'},
  ],
}) =>
    {
      'uid': 'her',
      'self': self,
      'blocked': false,
      'name': 'Dana',
      'age': 30,
      'location': 'Berlin',
      'photos': <String>[],
      'pages': pages,
      'liked': liked,
      'score': score,
      'thread_id': self ? null : 'her__me',
      'physical_attributes': physicalAttributes,
    };

Map<String, dynamic> _physical() => {
      'fields': {
        'hair_color': {'value': 'black', 'source': 'photo', 'confidence': 'high'},
        'eye_color': {'value': 'blue', 'source': 'stated', 'confidence': 'high'},
        'height_estimate_cm': {'value': null, 'source': 'none'},
        'build': {'value': 'unknown', 'source': 'none'},
      },
      'photo_count': 3,
    };

ApiClient _api(
  Map<String, dynamic> profile, {
  void Function(String path)? onPost,
  Map<String, dynamic>? compat,
  bool likeMutual = false,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore/profile/her') {
        return http.Response(jsonEncode(profile), 200);
      }
      if (req.method == 'POST') {
        onPost?.call(req.url.path);
        if (req.url.path == '/explore/like') {
          return http.Response(
              jsonEncode({'ok': true, 'mutual': likeMutual}), 200);
        }
        if (req.url.path == '/explore/unlike') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.url.path == '/check-compatibility') {
          return http.Response(
            jsonEncode(compat ?? {'ok': true, 'score': 0.67, 'match_id': 'm'}),
            200,
          );
        }
      }
      return http.Response('no', 404);
    }),
  );
}

Widget _app(ApiClient api, {List<String>? pushed}) {
  final router = GoRouter(
    initialLocation: '/profile/user/her',
    routes: [
      GoRoute(
        path: '/profile/user/:uid',
        builder: (_, s) =>
            PublicProfileScreen(uid: s.pathParameters['uid']!, api: api),
      ),
      GoRoute(
        path: '/dm/:threadId',
        builder: (_, s) {
          pushed?.add(s.pathParameters['threadId']!);
          return const Scaffold(body: Text('DM THREAD'));
        },
      ),
      GoRoute(
        path: '/match/:matchId',
        builder: (_, s) {
          pushed?.add('/match/${s.pathParameters['matchId']}');
          return const Scaffold(body: Text('MATCH REPORT'));
        },
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
      GoRoute(
        path: '/profile/usage',
        builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
    b.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  testWidgets('opening a profile sets the voice screen-context', (tester) async {
    addTearDown(AppContext.instance.clear);
    AppContext.instance.clear();

    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pump(); // initState, before the profile future resolves
    expect(AppContext.instance.current.value.screen, 'profile');
    expect(AppContext.instance.current.value.subjectUid, 'her');

    await tester.pumpAndSettle(); // name arrives
    expect(AppContext.instance.current.value.subjectName, 'Dana');
  });

  testWidgets('renders the public sections and actions', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.text('Dana'), findsWidgets); // title bar + header
    expect(find.text('From Lisbon, lives in Berlin.'), findsOneWidget);
    expect(find.text('Climbs and cooks.'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Like'), findsOneWidget);
    expect(find.text('Match report'), findsOneWidget);
    expect(find.text('Web search'), findsOneWidget);
  });

  testWidgets('Chat opens the DM thread', (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile()), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(pushed, ['her__me']);
  });

  testWidgets('Like posts and flips to Liked', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(_app(_api(_profile(), onPost: posts.add)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Like'));
    await tester.pumpAndSettle();

    expect(posts, contains('/explore/like'));
    expect(find.text('Liked'), findsOneWidget);
  });

  testWidgets('tapping Liked posts /explore/unlike and flips back to Like',
      (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(
        _app(_api(_profile(liked: true), onPost: posts.add)));
    await tester.pumpAndSettle();

    expect(find.text('Liked'), findsOneWidget);

    await tester.tap(find.text('Liked'));
    await tester.pumpAndSettle();

    expect(posts, contains('/explore/unlike'));
    expect(find.text('Like'), findsOneWidget);
    expect(find.text('Liked'), findsNothing);
  });

  testWidgets('unliking a mutual like confirms first', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(_app(
        _api(_profile(), onPost: posts.add, likeMutual: true)));
    await tester.pumpAndSettle();

    // Like in-session so the screen knows it's mutual.
    await tester.tap(find.text('Like'));
    await tester.pumpAndSettle();
    expect(find.text('Liked'), findsOneWidget);

    // Unlike → a confirm dialog; dismiss it and nothing is posted.
    await tester.tap(find.text('Liked'));
    await tester.pumpAndSettle();
    expect(find.text('Remove your like?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(posts, isNot(contains('/explore/unlike')));
    expect(find.text('Liked'), findsOneWidget);

    // Confirm this time → it posts and flips back.
    await tester.tap(find.text('Liked'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(posts, contains('/explore/unlike'));
    expect(find.text('Like'), findsOneWidget);
  });

  testWidgets('Run match calls the endpoint and opens the report',
      (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile()), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Match report'));
    await tester.pumpAndSettle();

    // Scored, then routed straight to the shareable match report.
    expect(pushed, contains('/match/m'));
    expect(find.text('MATCH REPORT'), findsOneWidget);
  });

  testWidgets('a scored pair shows the match button active, with no credit '
      'cost caption, and it still opens the report', (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile(score: 0.67)), pushed: pushed));
    await tester.pumpAndSettle();

    // Same rail button either way — the caption disappears once scored (a
    // recalc, which the tap still triggers, is free from here on).
    expect(find.text('Match report'), findsOneWidget);
    expect(find.text('12 cr'), findsNothing);

    await tester.tap(find.text('Match report'));
    await tester.pumpAndSettle();
    expect(pushed, contains('/match/m'));
    expect(find.text('MATCH REPORT'), findsOneWidget);
  });

  testWidgets('a capped Run match shows a Reload action that opens the reload '
      'screen', (tester) async {
    await tester.pumpWidget(_app(_api(
      _profile(),
      compat: {'ok': false, 'usage_capped': true},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Match report'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Reload'));
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('self view is titled "My public profile" and hides the actions',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.text('My public profile'), findsOneWidget);
    expect(find.text('Chat'), findsNothing);
    expect(find.text('Like'), findsNothing);
  });

  testWidgets('self view offers "Edit with Ayma" and it opens the edit chat',
      (tester) async {
    ChatInbox.instance.take(); // clear any leftover
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    await tester.tap(find.text('Edit with Ayma'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'talk_about');
    expect(k.editSelf, isTrue);
    expect(k.targetUid, 'her');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('own view renders the Physical section with source tags',
      (tester) async {
    await tester.pumpWidget(
      _app(_api(_profile(self: true, physicalAttributes: _physical()))),
    );
    await tester.pumpAndSettle();

    expect(find.text('PHYSICAL'), findsOneWidget);
    expect(find.text('Hair'), findsOneWidget);
    expect(find.text('black'), findsOneWidget);
    expect(find.text('from photos'), findsOneWidget);
    expect(find.text('Eyes'), findsOneWidget);
    expect(find.text('blue'), findsOneWidget);
    expect(find.text('from your answers'), findsOneWidget);
    // unknown / null values are dropped.
    expect(find.text('Build'), findsNothing);
    expect(find.text('Height (rough)'), findsNothing);
  });

  testWidgets('Physical section is hidden when there is no record',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();
    expect(find.text('PHYSICAL'), findsNothing);
  });

  testWidgets('Physical section never shows for another user', (tester) async {
    await tester.pumpWidget(
      _app(_api(_profile(physicalAttributes: _physical()))),
    );
    await tester.pumpAndSettle();
    expect(find.text('PHYSICAL'), findsNothing);
  });
}
