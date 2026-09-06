import 'dart:convert';

import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
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
    };

ApiClient _api(
  Map<String, dynamic> profile, {
  void Function(String path)? onPost,
  Map<String, dynamic>? compat,
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
          return http.Response(jsonEncode({'ok': true, 'mutual': false}), 200);
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

  testWidgets('renders the public sections and actions', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.text('Dana'), findsOneWidget);
    expect(find.text('From Lisbon, lives in Berlin.'), findsOneWidget);
    expect(find.text('Climbs and cooks.'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Like'), findsOneWidget);
    expect(find.text('Run match'), findsOneWidget);
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

  testWidgets('Run match calls the endpoint and shows the score',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run match'));
    await tester.pumpAndSettle();

    expect(find.text('67% match'), findsOneWidget);
    expect(find.text('Recalculate match'),
        findsOneWidget);
  });

  testWidgets('self view hides the action row', (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.text('Chat'), findsNothing);
    expect(find.text('Like'), findsNothing);
  });
}
