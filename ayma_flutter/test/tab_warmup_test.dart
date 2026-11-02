import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/services/tab_prefetch_coordinator.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

class _WarmApi extends ApiClient {
  _WarmApi() : super(auth: _auth());
  int exploreCalls = 0;
  int miniCalls = 0;

  @override
  Future<ExplorePage> explore({
    String q = '',
    Map<String, String> filters = const {},
    int limit = 24,
    String? cursor,
  }) async {
    exploreCalls++;
    return const ExplorePage(
      cards: [
        ExploreCard(uid: 'w', name: 'Warm', age: 30, location: 'X'),
      ],
    );
  }

  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async {
    miniCalls++;
    return {
      for (final u in uids)
        u: MiniProfile(name: 'N-$u', photo: '', online: false),
    };
  }
}

class _WarmDm extends DmService {
  _WarmDm() : super(auth: _auth());

  List<DmThread> get _threads => [
        DmThread(
          threadId: 'a__me',
          otherUid: 'a',
          lastMessageAt: DateTime(2026, 1, 2),
        ),
      ];

  @override
  Future<List<DmThread>> fetchActiveThreads({int limit = 25}) async =>
      _threads;

  @override
  Stream<List<DmThread>> watchThreads({int limit = 25}) =>
      Stream.value(_threads);
}

class _NoMatches extends MatchService {
  _NoMatches() : super(auth: _auth());
  @override
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) =>
      Stream.value(const []);
}

void main() {
  setUp(TabPrefetchCoordinator.instance.debugReset);
  tearDown(TabPrefetchCoordinator.instance.debugReset);

  testWidgets('idle warm-up caches explore page 1 + conversation minis',
      (tester) async {
    final api = _WarmApi();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    TabPrefetchCoordinator.instance.scheduleIdleWarmup(api: api, dm: _WarmDm());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(api.exploreCalls, 1);
    expect(api.miniCalls, 1);
    final page = TabPrefetchCoordinator.instance.takeExplorePage();
    expect(page!.cards.single.name, 'Warm');
    expect(TabPrefetchCoordinator.instance.takeExplorePage(), isNull);
    final minis = TabPrefetchCoordinator.instance.takeMiniProfiles();
    expect(minis['a']!.name, 'N-a');
    expect(TabPrefetchCoordinator.instance.takeMiniProfiles(), isEmpty);
  });

  testWidgets('explore paints the warmed page before the network answers',
      (tester) async {
    TabPrefetchCoordinator.instance.debugSeed(
      explore: const ExplorePage(
        cards: [ExploreCard(uid: 'w', name: 'Warm', age: 30, location: 'X')],
      ),
    );
    final gate = Completer<List<Map<String, dynamic>>>();
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore') {
          final cards = await gate.future;
          return http.Response(jsonEncode({'cards': cards}), 200);
        }
        return http.Response('no', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: ExploreScreen(apiClient: api)));
    await tester.pump(); // frames run; the network is still gated

    expect(find.text('Warm'), findsOneWidget); // instant paint, no spinner

    gate.complete([
      {'uid': 'f', 'name': 'Fresh', 'age': 31, 'location': 'Y'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Fresh'), findsOneWidget); // background revalidation
    expect(find.text('Warm'), findsNothing);
  });

  testWidgets('messages renders warmed minis without refetching',
      (tester) async {
    TabPrefetchCoordinator.instance.debugSeed(minis: {
      'a': const MiniProfile(name: 'Warm Ann', photo: '', online: true),
    });
    final api = _WarmApi();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: MessagesScreen(
        dmService: _WarmDm(),
        matchService: _NoMatches(),
        apiClient: api,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Warm Ann'), findsOneWidget);
    expect(api.miniCalls, 0); // served from the warm-up, not the network
  });
}
