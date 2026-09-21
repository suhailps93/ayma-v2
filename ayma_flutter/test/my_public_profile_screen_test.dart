// MyPublicProfileScreen: an AppBar, the photo carousel + name/age/location
// header (fetched via GET /explore/profile/{uid} — the SAME endpoint and
// SAME `ProfilePhotoHeader` widget the Explore-facing profile screen and the
// match-request screen use), plus the shared LivingReportView renderer over
// the converged `story_public` Living Report (§ founder direction
// 2026-09-20: physical-attribute fields + public Story narrative, one
// document). Distinct from PublicProfileScreen (`/profile/user/:uid`, the
// Explore-facing "someone else's profile" screen), which is untouched.
import 'dart:convert';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart'
    show ProfilePhotoHeader;
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
    expect(find.byType(ProfilePhotoHeader), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('LISBON'), findsOneWidget);

    // The existing Living Report block content (Attributes/Identity/etc.)
    // still renders, unchanged, below the photo header.
    expect(find.text('Brown'), findsOneWidget);
  });
}
