// MyPublicProfileScreen: an AppBar, the photo carousel + name/age/location
// header (fetched via GET /explore/profile/{uid} — the SAME endpoint and
// SAME `ProfilePhotoHeader` widget the Explore-facing profile screen and the
// match-request screen use), plus the shared LivingReportView renderer over
// the converged `story_public` Living Report (§ founder direction
// 2026-09-20: physical-attribute fields + public Story narrative, one
// document). Its content is the shared ProfileBody, which PublicProfileScreen
// (`/profile/user/:uid`) renders too — see public_profile_screen_test.dart
// for the parity test.
import 'dart:convert';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart'
    show ProfileBody, ProfilePhotoHeader;
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
          'title': 'Story',
          'sections': [
            {
              'heading': 'Attributes',
              'blocks': [
                {
                  'block_id': 'attr:eye_color',
                  'type': 'attribute',
                  'editable': true,
                  'label': 'Eyes',
                  'value': 'Brown',
                },
              ],
            },
          ],
          'meta': {
            'owner_uid': 'u1',
            'viewer_can_edit': true,
            'created_at': null,
            'updated_at': null,
          },
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
    expect(requestedPaths, contains('/report/story_public/u1'));
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
      // Minimal, new-account story_public: one real IDENTITY section only.
      return http.Response(
        jsonEncode({
          'title': 'Story',
          'sections': [
            {
              'heading': 'IDENTITY',
              'blocks': [
                {
                  'block_id': 'attr:goes_by',
                  'type': 'attribute',
                  'editable': true,
                  'label': 'Goes by',
                  'value': 'Alex',
                },
              ],
            },
          ],
          'meta': {
            'owner_uid': 'u1',
            'viewer_can_edit': true,
            'created_at': null,
            'updated_at': null,
          },
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
        jsonEncode({
          'title': 'Story',
          'sections': [],
          'meta': {
            'owner_uid': 'u1',
            'viewer_can_edit': true,
            'created_at': null,
            'updated_at': null,
          },
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

    final banner = tester.widget<MaterialBanner>(find.byType(MaterialBanner));
    expect(banner.padding,
        const EdgeInsetsDirectional.only(start: 20, top: 2));

    final review =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Review'));
    expect(
        review.style!.minimumSize!.resolve(const <WidgetState>{})!.height, 44);
  });
}
