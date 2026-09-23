import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/matches_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeMatchService extends MatchService {
  _FakeMatchService(this._matches, {Map<String, MatchView>? byId})
      : _byId = byId ?? const {},
        super(auth: MockFirebaseAuth(signedIn: true));

  final List<MatchView> _matches;
  final Map<String, MatchView> _byId;
  final List<(String, bool)> responded = [];

  @override
  Stream<List<MatchView>> watchNewMatches() =>
      Stream.value(_matches);

  @override
  Future<MatchView> fetchMatch(String matchId) async {
    final m = _byId[matchId];
    if (m == null) throw StateError('No such match: $matchId');
    return m;
  }

  @override
  Future<void> respond(String matchId, {required bool accept}) async {
    responded.add((matchId, accept));
  }
}

const _m = MatchView(
  matchId: 'a__me',
  otherUid: 'a',
  otherName: 'Robin',
  score: 0.82,
  myExplanation: 'You both want a calm home life and value directness.',
  status: 'scored',
);

/// A realistic `/explore/profile/{uid}` response — the same shape the real
/// public profile screen renders (photo, name, age, location, bio pages).
Map<String, dynamic> _profileJson({String name = 'Robin'}) => {
      'uid': 'a',
      'self': false,
      'blocked': false,
      'name': name,
      'age': 29,
      'location': 'Lisbon',
      'photos': <String>[],
      'pages': [
        {'page_type': 'identity', 'title': '', 'body': 'Grew up by the sea.'},
        {'page_type': 'interests', 'title': '', 'body': 'Surfing and design.'},
      ],
      'liked': false,
      'score': 0.82,
      'thread_id': 'a__me',
      'has_chatted': false,
      'physical_attributes': null,
    };

ApiClient _fakeApi({Map<String, dynamic>? profile}) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore/profile/a') {
          return http.Response(jsonEncode(profile ?? _profileJson()), 200);
        }
        return http.Response('no', 404);
      }),
    );

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

  testWidgets('lists match cards and opens the detail with the full profile',
      (tester) async {
    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(
          home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Robin'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);

    await tester.tap(find.text('Robin'));
    // Not pumpAndSettle from here down: the detail screen is now wrapped in
    // `NavBarShell` (§ persistent nav bar, every screen), whose bar carries a
    // perpetually-animating `AymaOrb` — same reason main_shell_screen_test.dart
    // uses bounded pumps around its own orb instead of pumpAndSettle. Two
    // 300ms steps (not one): the push transition (a standard 300ms
    // `MaterialPageRoute` animation) needs to fully finish, or the covered
    // `MatchesScreen` route underneath isn't yet marked offstage and its own
    // still-visible match card (a truncated, 3-line copy of the same
    // explanation text) makes `find.text` below match twice.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Ayma's score + blurb are still there, as an addition...
    expect(find.text('82% match'), findsOneWidget);
    expect(find.text('You both want a calm home life and value directness.'),
        findsOneWidget);
    expect(find.text('Pass'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    // ...on top of the same full public profile the profile screen shows —
    // name, age, location, bio sections — not the bare "Someone" placeholder.
    expect(find.text('Robin'), findsWidgets); // title bar + header
    expect(find.text('Lisbon'), findsOneWidget);
    expect(find.text('Grew up by the sea.'), findsOneWidget);
    expect(find.text('Surfing and design.'), findsOneWidget);
  });

  testWidgets(
      'reached via a route (a notification tap) with only the matchId '
      'fetches the match and its full profile', (tester) async {
    final svc = _FakeMatchService(const [], byId: {'a__me': _m});
    await tester.pumpWidget(MaterialApp(
      home: MatchDetailScreen(
        matchId: 'a__me',
        service: svc,
        api: _fakeApi(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('82% match'), findsOneWidget);
    expect(find.text('Robin'), findsWidgets);
    expect(find.text('Grew up by the sea.'), findsOneWidget);
  });

  testWidgets('accept posts the response and shows confirmation',
      (tester) async {
    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(
          home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Robin'));
    // See the note in the test above — the detail screen's `NavBarShell` bar
    // never settles, so bounded pumps from here down instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(svc.responded, [('a__me', true)]);
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: _FakeMatchService(const []))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No new matches yet'), findsOneWidget);
  });
}
