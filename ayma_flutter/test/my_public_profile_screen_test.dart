// MyPublicProfileScreen: an AppBar plus the shared LivingReportView renderer
// over the converged `story_public` Living Report (§ founder direction
// 2026-09-20: physical-attribute fields + public Story narrative, one
// document). Distinct from PublicProfileScreen (`/profile/user/:uid`, the
// Explore-facing "someone else's profile" screen), which is untouched.
import 'dart:convert';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('fetches GET /report/story_public/{uid} and renders it',
      (tester) async {
    String? requestedPath;
    final mockHttp = MockClient((request) async {
      requestedPath = request.url.path;
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

    expect(requestedPath, '/report/story_public/u1');
    expect(find.text('My public profile'), findsOneWidget); // AppBar title
    expect(find.text('Brown'), findsOneWidget);
  });
}
