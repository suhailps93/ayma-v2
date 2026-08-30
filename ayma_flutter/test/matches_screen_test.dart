import 'dart:async';

import 'package:ayma_flutter/screens/matches_screen.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMatchService extends MatchService {
  _FakeMatchService(this._matches)
      : super(auth: MockFirebaseAuth(signedIn: true));

  final List<MatchView> _matches;
  final List<(String, bool)> responded = [];

  @override
  Stream<List<MatchView>> watchNewMatches() =>
      Stream.value(_matches);

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

void main() {
  testWidgets('lists match cards and opens the detail', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: svc)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Robin'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);

    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();
    expect(find.text('82% match'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
  });

  testWidgets('accept posts the response and shows confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: svc)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(svc.responded, [('a__me', true)]);
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('empty state', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: _FakeMatchService(const []))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No new matches yet'), findsOneWidget);
  });
}
