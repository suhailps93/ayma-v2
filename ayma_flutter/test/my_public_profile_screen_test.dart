// MyPublicProfileScreen: an AppBar, the photo carousel + name/age/location
// header (fetched via GET /explore/profile/{uid} — the SAME endpoint and
// SAME `ProfilePhotoHeader` widget the Explore-facing profile screen and the
// match-request screen use), plus the shared Node-Visualiser renderer over
// the converged `story_public` public graph (§ founder direction
// 2026-09-20: physical-attribute fields + public Story narrative, one
// document). Its content is the shared ProfileBody, which PublicProfileScreen
// (`/profile/user/:uid`) renders too — see public_profile_screen_test.dart
// for the parity test.
import 'dart:convert';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart'
    show ProfileBody, ProfilePhotoHeader;
import 'package:ayma_flutter/screens/story_editor_screen.dart'
    show StoryEditorScreen;
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A minimal backend for the My-public-profile screen: the photo header read
/// and a tiny `story_public` report, enough to render the screen + its pencil.
MockClient _profileBackend() => MockClient((request) async {
      if (request.url.path == '/explore/profile/u1') {
        return http.Response(
          jsonEncode({
            'uid': 'u1', 'self': true, 'blocked': false, 'name': 'Sam',
            'age': 29, 'location': 'Lisbon',
            'photos': ['https://example.com/p1.jpg'], 'pages': [],
            'liked': false, 'score': null, 'thread_id': null,
            'has_chatted': false,
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // The body now renders the Node-Visualiser tree (2o): empty here.
      return http.Response(
        jsonEncode({'surface': 'publicProfile', 'sections': const []}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

void main() {
  // A tall physical surface — same as public_profile_screen_test.dart — so
  // the outer ListView lays out both the photo header AND the (shrinkWrap)
  // Living Report content below it without needing an actual scroll; the
  // default small test surface would leave the report off-screen and
  // unbuilt (Sliver lazy-building), making its text unfindable even though
  // it's really there.
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

  testWidgets(
      'renders the photo carousel header alongside the Living Report content',
      (tester) async {
    final requestedPaths = <String>[];
    final mockHttp = MockClient((request) async {
      requestedPaths.add(request.url.path);
      if (request.url.path == '/explore/profile/u1') {
        return http.Response(
          jsonEncode({
            'uid': 'u1',
            'self': true,
            'blocked': false,
            'name': 'Sam',
            'age': 29,
            'location': 'Lisbon',
            'photos': ['https://example.com/p1.jpg'],
            'pages': [],
            'liked': false,
            'score': null,
            'thread_id': null,
            'has_chatted': false,
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode({
          'surface': 'publicProfile',
          'sections': [
            {
              'page_type': 'identity',
              'title': 'Attributes',
              'order': 0,
              'nodes': [
                {
                  'id': 'n0',
                  'section': 'identity',
                  'label': 'Eyes',
                  'text': 'Brown',
                  'answer_type': 'text',
                  'level': 1,
                  'visibility': 'public',
                  'subtree_visibility': 'public',
                },
              ],
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(
      home: MyPublicProfileScreen(myUid: 'u1', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/explore/profile/u1'));
    // Self view fetches the public tree as "mine".
    expect(requestedPaths, contains('/profile/graph/tree'));
    expect(find.text('My public profile'), findsOneWidget); // AppBar title

    // The photo carousel + name/age/location header renders — the bug this
    // screen shipped with was showing no photos at all.
    expect(find.byType(ProfileBody), findsOneWidget);
    expect(find.byType(ProfilePhotoHeader), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Lisbon'), findsOneWidget);

    // The existing Living Report block content (Attributes/Identity/etc.)
    // still renders, unchanged, below the photo header.
    expect(find.text('Brown'), findsOneWidget);

    // The report's own "Story" headline is not repeated above the content.
    expect(find.text('Story'), findsNothing);
  });

  // R2-C7 regression: on a brand-new account the "My public profile" screen
  // must render the clean single-layer layout (hero photo header, name/age,
  // photo strip, real sections) and scroll — never compose the "My story"
  // cover (placeholder stats "TOPICS / PHOTOS / WEB FINDS", the "Ayma keeps
  // learning…" banner, the "A few glimpses into my world" photos section) on
  // top of the real profile. Those cover strings belong only to the standalone
  // Story screen; none of them may appear here.
  testWidgets('new-account public profile renders the clean single-layer '
      'layout (no story cover) and scrolls — R2-C7', (tester) async {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/explore/profile/u1') {
        return http.Response(
          jsonEncode({
            'uid': 'u1',
            'self': true,
            'blocked': false,
            'name': 'Alex',
            'age': 33,
            'location': 'San Jose, United States',
            'photos': [
              'https://example.com/a.jpg',
              'https://example.com/b.jpg',
            ],
            'pages': [],
            'liked': false,
            'score': null,
            'thread_id': null,
            'has_chatted': false,
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // Minimal, new-account public tree: one real IDENTITY section only.
      return http.Response(
        jsonEncode({
          'surface': 'publicProfile',
          'sections': [
            {
              'page_type': 'identity',
              'title': 'IDENTITY',
              'order': 0,
              'nodes': [
                {
                  'id': 'n0',
                  'section': 'identity',
                  'label': 'Goes by',
                  'text': 'Alex',
                  'answer_type': 'text',
                  'level': 1,
                  'visibility': 'public',
                  'subtree_visibility': 'public',
                },
              ],
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(
      home: MyPublicProfileScreen(myUid: 'u1', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // The clean single layer: one photo header + the real section content.
    expect(find.byType(ProfileBody), findsOneWidget);
    expect(find.byType(ProfilePhotoHeader), findsOneWidget);
    expect(find.text('Alex'), findsWidgets); // name on the header
    expect(find.text('IDENTITY'), findsOneWidget); // real section

    // No "My story" cover layer composed over it: none of its placeholder
    // stat / banner / photos-section strings may appear.
    expect(find.textContaining('TOPICS'), findsNothing);
    expect(find.textContaining('WEB FINDS'), findsNothing);
    expect(find.textContaining('A few glimpses into my world'), findsNothing);
    expect(
        find.textContaining('Ayma keeps learning about you'), findsNothing);

    // The page is scrollable (its content lives in one scroll view), and it
    // laid out with no overflow — pumpAndSettle above would have thrown on a
    // RenderFlex overflow exception.
    expect(
      find.descendant(
          of: find.byType(ProfileBody), matching: find.byType(Scrollable)),
      findsWidgets,
    );
  });

  // Founder-hit Nov 16: the pencil (tooltip "Edit manually") used to open the
  // legacy markdown editor (ManualProfileEditScreen) — the replaced paragraph
  // path that should have been deleted when bullets shipped. The settled design
  // is that manual editing IS the bullet editor (Your Story), so the pencil must
  // route to StoryEditorScreen.path and no markdown editor may be reachable.
  testWidgets('the pencil (Edit manually) opens the bullet editor '
      '(StoryEditorScreen), not a markdown editor', (tester) async {
    final api = ApiClient(
        httpClient: _profileBackend(), auth: MockFirebaseAuth(signedIn: true));
    var openedWiki = false;

    final router = GoRouter(
      initialLocation: '/me',
      routes: [
        GoRoute(
          path: '/me',
          builder: (_, __) =>
              MyPublicProfileScreen(myUid: 'u1', apiClient: api),
        ),
        GoRoute(
          path: StoryEditorScreen.path, // '/profile/wiki' — the bullet editor
          builder: (_, __) {
            openedWiki = true;
            return const Scaffold(body: Text('BULLET EDITOR'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit manually'));
    await tester.pumpAndSettle();

    // The pencil navigated to the bullet editor route — not a pushed markdown
    // editor (which no longer exists in the codebase at all).
    expect(openedWiki, isTrue);
    expect(find.text('BULLET EDITOR'), findsOneWidget);
  });

  // Jobs pass (cluster 8): the pending-updates MaterialBanner shares the
  // profile body's 20 left edge (M3 single-row default is start 16), keeps the
  // M3 top 2, and its Review action clears the 44 touch floor.
  testWidgets('pending-updates banner sits at the 20 edge; Review is >= 44',
      (tester) async {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/profile/proposals') {
        return http.Response(
          jsonEncode({
            'proposals': [
              {
                'page_id': 'identity',
                'title': 'Identity',
                'changes': [
                  {'id': 'c1', 'op': 'add', 'text': 'A new line'},
                ],
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/explore/profile/u1') {
        return http.Response(
          jsonEncode({
            'uid': 'u1',
            'self': true,
            'blocked': false,
            'name': 'Sam',
            'age': 29,
            'location': 'Lisbon',
            'photos': ['https://example.com/p1.jpg'],
            'pages': [],
            'liked': false,
            'score': null,
            'thread_id': null,
            'has_chatted': false,
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode({'surface': 'publicProfile', 'sections': []}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: MyPublicProfileScreen(myUid: 'u1', apiClient: api),
    ));
    await tester.pumpAndSettle();

    final banner = tester.widget<MaterialBanner>(find.byType(MaterialBanner));
    expect(banner.padding,
        const EdgeInsetsDirectional.only(start: 20, top: 2));

    // Local Size(0,44) override removed (T3); the app theme now renders Review
    // at 48 (padded tap target), clearing the 44 floor.
    expect(
        tester.getSize(find.widgetWithText(TextButton, 'Review')).height, 48);
  });
}
