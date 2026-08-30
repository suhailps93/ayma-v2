import 'dart:convert';

import 'package:ayma_flutter/screens/admin_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

ApiClient _api() {
  final mock = MockClient((req) async {
    expect(req.headers['X-Admin-Password'], 'secret');
    if (req.url.path == '/admin/users') {
      return http.Response(
        jsonEncode({
          'users': [
            {
              'uid': 'alice',
              'name': 'Alice Wonder',
              'community': 'lx',
              'session_mode': 'active',
              'paused': true,
              'trust_flags': 1,
            }
          ]
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'uid': 'alice',
        'account': {'session_mode': 'active'},
        'profile': {'name': 'Alice Wonder'},
        'trust_flags': [
          {'type': 'face_mismatch'}
        ],
        'wiki_pages': [
          {'page_id': 'career', 'visibility': 'private'}
        ],
        'matches': [],
        'dm_threads': [],
        'deleted_account': null,
      }),
      200,
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('unlock -> search -> open detail', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: AdminScreen(api: _api()),
    ));
    await tester.pumpAndSettle();

    // Locked: password field + Unlock.
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    // Search.
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(find.text('Alice Wonder'), findsOneWidget);
    expect(find.textContaining('paused'), findsOneWidget);

    // Open detail.
    await tester.tap(find.text('Alice Wonder'));
    await tester.pumpAndSettle();
    expect(find.text('wiki_pages'), findsOneWidget);
    expect(find.text('trust_flags'), findsOneWidget);
    expect(find.textContaining('face_mismatch'), findsOneWidget);
  });
}
