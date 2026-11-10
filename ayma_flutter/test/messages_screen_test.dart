import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/overflow_guards.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Jobs pass cluster 15 (fleet/jobs-messages-reaudit): spacing / colour /
// alignment regressions for the Messages tab — empty-state padding (defect
// 21), avatar initials colour (defect 22), the Matched pill (defect 23) and
// the unread badge count (defect 24). Colour assertions pump without an
// explicit theme, so `context.ac` falls back to `AymaTokens.dark` — the
// values below are therefore the dark-theme tokens.

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

Future<void> _thread(FakeFirebaseFirestore fs, String other, int unread) =>
    fs.doc('dm_threads/${other}__me').set({
      'participants': [other, 'me'],
      'last_message_at': Timestamp.now(),
      'last_read_at': <String, dynamic>{},
      'unread': <String, dynamic>{'me': unread, other: 0},
    });

class _NoMatches extends MatchService {
  _NoMatches() : super(auth: _auth());
  @override
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) =>
      Stream.value(const []);
  @override
  Stream<FreshData<List<MatchView>>> watchMutualMatchesFresh(
          {int limit = 25}) =>
      Stream.value(const FreshData(data: []));
}

class _MatchesWith extends MatchService {
  _MatchesWith(this._list) : super(auth: _auth());
  final List<MatchView> _list;
  @override
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) =>
      Stream.value(_list);
  @override
  Stream<FreshData<List<MatchView>>> watchMutualMatchesFresh(
          {int limit = 25}) =>
      Stream.value(FreshData(data: _list));
}

class _ApiWith extends ApiClient {
  _ApiWith(this._minis) : super(auth: _auth());
  final Map<String, MiniProfile> _minis;
  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async =>
      _minis;
}

const _match = MatchView(
  matchId: 'a__me',
  otherUid: 'a',
  otherName: 'Zara',
  score: 0.82,
  myExplanation: 'You both value directness.',
  status: 'scored',
);

void main() {
  testWidgets('empty state pads horizontal 40 (defect 21)', (tester) async {
    final fs = FakeFirebaseFirestore();
    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(
        dmService: DmService(auth: _auth(), firestore: fs),
        matchService: _NoMatches(),
        apiClient: _ApiWith(const {}),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('No matches or conversations yet'),
        findsOneWidget);
    final scroll = tester.widget<CenteredScroll>(find.byType(CenteredScroll));
    expect(scroll.padding, const EdgeInsets.symmetric(horizontal: 40));
  });

  testWidgets('avatar initial renders in fgDim (defect 22)', (tester) async {
    final fs = FakeFirebaseFirestore();
    await _thread(fs, 'a', 0);
    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(
        dmService: DmService(auth: _auth(), firestore: fs),
        matchService: _NoMatches(),
        apiClient:
            _ApiWith(const {'a': MiniProfile(name: 'Zara', photo: '')}),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initial = tester.widget<Text>(find.text('Z'));
    expect(initial.style?.color, AymaTokens.dark.fgDim);
  });

  testWidgets('Matched pill is an accentFaint fill with an accentText label '
      '(defect 23)', (tester) async {
    final fs = FakeFirebaseFirestore();
    await _thread(fs, 'a', 0);
    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(
        dmService: DmService(auth: _auth(), firestore: fs),
        matchService: _MatchesWith(const [_match]),
        apiClient:
            _ApiWith(const {'a': MiniProfile(name: 'Zara', photo: '')}),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final label = tester.widget<Text>(find.text('Matched'));
    expect(label.style?.color, AymaTokens.dark.accentText);

    final pill = tester.widget<Container>(
      find.ancestor(of: find.text('Matched'), matching: find.byType(Container)),
    );
    expect((pill.decoration as BoxDecoration).color,
        AymaTokens.dark.accentFaint);
  });

  testWidgets('unread badge count is onAccent on the accent badge (defect 24)',
      (tester) async {
    final fs = FakeFirebaseFirestore();
    await _thread(fs, 'a', 3);
    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(
        dmService: DmService(auth: _auth(), firestore: fs),
        matchService: _NoMatches(),
        apiClient:
            _ApiWith(const {'a': MiniProfile(name: 'Zara', photo: '')}),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final badge = tester.widget<Container>(
      find.byKey(const ValueKey('unread-badge')),
    );
    expect((badge.decoration as BoxDecoration).color, AymaTokens.dark.accent);

    final count = tester.widget<Text>(find.text('3'));
    expect(count.style?.color, AymaTokens.dark.onAccent);
  });
}
