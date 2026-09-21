import 'dart:convert';

import 'package:ayma_flutter/screens/photo_candidates_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

List<Map<String, dynamic>> _candidates() => [
      {
        'candidate_id': 'c1',
        'image_url': 'https://example.invalid/c1.png',
        'match_type': 'full',
        'source_url': 'https://socialsite.example/p/1',
        'source_title': 'Jamie at the lake',
        'source_domain': 'socialsite.example',
        'status': 'pending',
        'created_at': '2026-09-10T10:00:00',
        'found_from': 'uploads/u1/photo_1.jpg',
      },
      {
        'candidate_id': 'c2',
        'image_url': 'https://example.invalid/c2.png',
        'match_type': 'partial',
        'source_url': 'https://other.example/x',
        'source_title': 'Team photo',
        'source_domain': 'other.example',
        'status': 'pending',
        'created_at': '2026-09-09T10:00:00',
        'found_from': 'uploads/u1/photo_1.jpg',
      },
    ];

/// An ApiClient over a fake HTTP layer: serves [candidates] from
/// `GET .../candidates`, and records every confirm/reject call it receives
/// in [decisions] as `(candidateId, confirmed)`.
ApiClient _api(
  List<Map<String, dynamic>> candidates,
  List<(String, bool)> decisions,
) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' &&
        request.url.path == '/web-search/photos/candidates') {
      return http.Response(
          jsonEncode({'candidates': candidates}), 200, headers: _jsonUtf8);
    }
    final confirmMatch =
        RegExp(r'^/web-search/photos/candidates/([^/]+)/confirm$')
            .firstMatch(request.url.path);
    if (request.method == 'POST' && confirmMatch != null) {
      decisions.add((confirmMatch.group(1)!, true));
      return http.Response(
          jsonEncode({'ok': true, 'candidate': {}}), 200, headers: _jsonUtf8);
    }
    final rejectMatch =
        RegExp(r'^/web-search/photos/candidates/([^/]+)/reject$')
            .firstMatch(request.url.path);
    if (request.method == 'POST' && rejectMatch != null) {
      decisions.add((rejectMatch.group(1)!, false));
      return http.Response(
          jsonEncode({'ok': true, 'candidate': {}}), 200, headers: _jsonUtf8);
    }
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('lists pending candidates with their source info',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api(_candidates(), []);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoCandidatesScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Jamie at the lake'), findsOneWidget);
    expect(find.text('socialsite.example'), findsOneWidget);
    expect(find.text('Team photo'), findsOneWidget);
    expect(find.text('other.example'), findsOneWidget);
    expect(find.text('This is me'), findsNWidgets(2));
    expect(find.text('Not me'), findsNWidgets(2));
  });

  testWidgets('confirming a candidate calls confirm and removes the row',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final decisions = <(String, bool)>[];
    final api = _api(_candidates(), decisions);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoCandidatesScreen(api: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('This is me').first);
    await tester.pumpAndSettle();

    expect(decisions, [('c1', true)]);
    expect(find.text('Jamie at the lake'), findsNothing);
    expect(find.text('Team photo'), findsOneWidget);
  });

  testWidgets('rejecting a candidate calls reject and removes the row',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final decisions = <(String, bool)>[];
    final api = _api(_candidates(), decisions);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoCandidatesScreen(api: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not me').first);
    await tester.pumpAndSettle();

    expect(decisions, [('c1', false)]);
    expect(find.text('Jamie at the lake'), findsNothing);
  });

  testWidgets('shows an empty state when there are no pending candidates',
      (tester) async {
    final api = _api(const [], []);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoCandidatesScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing left to review'), findsOneWidget);
  });
}
