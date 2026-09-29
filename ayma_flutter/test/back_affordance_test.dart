import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/screens/profile_tab_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Founder issue (iPhone testers): every pushed screen needs a visible way
/// back — iPhones have no system back button. The screens that double as
/// shell tabs (Messages / Explore / You) had no back affordance at all when
/// pushed standalone (deep links, Ayma's `open_screen` voice tool); their
/// headers now imply a [BackButton] whenever the route can actually pop —
/// and, critically, still render none as a shell tab.
void main() {
  final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

  ApiClient api() => ApiClient(
        auth: auth,
        httpClient: MockClient((req) async {
          if (req.url.path == '/explore') {
            return http.Response(jsonEncode({'cards': []}), 200);
          }
          return http.Response('{}', 200,
              headers: const {'content-type': 'application/json'});
        }),
      );

  Widget screenFor(String which) {
    switch (which) {
      case 'messages':
        final firestore = FakeFirebaseFirestore();
        return MessagesScreen(
          dmService: DmService(auth: auth, firestore: firestore, api: api()),
          matchService:
              MatchService(auth: auth, firestore: firestore, api: api()),
          apiClient: api(),
        );
      case 'explore':
        return ExploreScreen(apiClient: api());
      case 'profile':
        return ProfileTabScreen(auth: auth, apiClient: api());
    }
    throw ArgumentError(which);
  }

  for (final which in ['messages', 'explore', 'profile']) {
    testWidgets('$which: back arrow when pushed, none as a root/tab',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.push('/pushed'),
                  child: const Text('PUSH'),
                ),
              ),
            ),
          ),
          GoRoute(path: '/pushed', builder: (_, __) => screenFor(which)),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PUSH'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget,
          reason: '$which pushed standalone must show a way back');

      // And it actually goes back.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('PUSH'), findsOneWidget);
    });

    testWidgets('$which: no back arrow when it cannot pop', (tester) async {
      await tester.pumpWidget(MaterialApp(home: screenFor(which)));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing,
          reason: '$which as a shell tab (root route) must stay arrow-free');
    });
  }
}
