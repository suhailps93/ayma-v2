import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

class _Api extends ApiClient {
  _Api()
      : super(
          auth: _auth(),
          httpClient: MockClient((req) async {
            return http.Response('{}', 200);
          }),
        );

  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async => {
        for (final u in uids)
          u: MiniProfile(name: 'Mini $u', photo: '', online: false),
      };
}

class _Dm extends DmService {
  _Dm() : super(auth: _auth());

  @override
  Stream<FreshData<List<DmThread>>> watchThreadsFresh({int limit = 25}) =>
      Stream.value(FreshData(data: [
        DmThread(
          threadId: 'a__me',
          otherUid: 'a',
          lastMessageAt: DateTime(2026, 1, 1),
        ),
      ]));

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(String threadId,
          {int limit = 30}) =>
      Stream.value(FreshData(data: [
        DmMessage(
          id: 'm1',
          senderUid: 'a',
          type: 'text',
          body: 'hello there',
          createdAt: DateTime(2026, 1, 1),
        ),
      ]));

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async =>
      DmAssist.empty;
}

class _Matches extends MatchService {
  _Matches() : super(auth: _auth());

  @override
  Stream<FreshData<List<MatchView>>> watchMutualMatchesFresh(
          {int limit = 25}) =>
      Stream.value(const FreshData(data: []));
}

void main() {
  // Regression guard for founder feedback item 6 (2026-11-06): tapping a
  // conversation must open its DM thread and STAY there — not bounce back
  // to the conversations list.
  testWidgets('tapping a conversation opens the DM thread and stays there',
      (tester) async {
    final dm = _Dm();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: MessagesScreen(
              dmService: dm,
              matchService: _Matches(),
              apiClient: _Api(),
            ),
          ),
        ),
        GoRoute(
          path: '/dm/:threadId',
          builder: (context, state) => DmThreadScreen(
            threadId: state.pathParameters['threadId']!,
            dmService: dm,
            apiClient: _Api(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.light,
      routerConfig: router,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Mini a'), findsOneWidget);

    await tester.tap(find.text('Mini a'));
    await tester.pumpAndSettle();

    expect(router.state.uri.toString(), '/dm/a__me');
    expect(find.byType(DmThreadScreen), findsOneWidget);
    expect(find.text('hello there'), findsOneWidget);

    // Later stream activity / frames must not bounce the user back to the
    // conversations list.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(router.state.uri.toString(), '/dm/a__me');
    expect(find.byType(DmThreadScreen), findsOneWidget);
  });
}
