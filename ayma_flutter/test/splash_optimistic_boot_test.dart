// Optimistic cold start (founder 2026-10-28: "during initial boot-up it takes
// a while… should we just show the cached page and bootstrap in the backend?"
// — yes). With a cached entry route for the signed-in user, the splash shows
// the cached screen after a short dwell (so the wake line is actually visible)
// and runs the full bootstrap in the background:
//  - it shows the cached screen without waiting on the bootstrap future;
//  - if bootstrap reveals the session is signed out (token rejected), it
//    corrects the optimistic UI to sign-in — the existing hardening, layered,
//    not removed.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

MockFirebaseAuth _auth() => MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'u1', email: 'a@b.co', isAnonymous: false),
    );

GoRouter _router(ApiClient api) => GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(apiClient: api, auth: _auth()),
        ),
        GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
      ],
    );

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}

void main() {
  testWidgets(
      'shows the cached shell immediately without waiting on the bootstrap '
      'future', (tester) async {
    // A cached entry route for this uid, and a bootstrap that is GATED so it
    // cannot have resolved when we assert.
    SharedPreferences.setMockInitialValues({'boot_route:u1': '/'});
    final gate = Completer<void>();
    final api = ApiClient(
      auth: _auth(),
      httpClient: MockClient((req) async {
        if (req.url.path == '/bootstrap') {
          await gate.future;
          return http.Response(
            jsonEncode({
              'session_mode': 'active',
              'uid': 'u1',
              'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      }),
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(api)));
    // Let the fast cache read + optimistic navigation run — the bootstrap
    // future is still gated (unresolved). The splash holds for its minimum
    // dwell first (so the wake line is actually visible), then navigates.
    await tester.pump();
    await tester.pump(SplashScreen.minSplashDwell);
    await tester.pump();

    expect(find.text('screen:shell'), findsOneWidget);
    expect(find.text('screen:signin'), findsNothing);

    // Release the gated bootstrap so the test leaves no pending work. It
    // resolves to the same route, so the shell stays.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('screen:shell'), findsOneWidget);
  });

  testWidgets('corrects the optimistic UI to sign-in when bootstrap is '
      'signed out (token rejected)', (tester) async {
    SharedPreferences.setMockInitialValues({'boot_route:u1': '/'});
    final api = ApiClient(
      auth: _auth(),
      httpClient: MockClient((req) async {
        if (req.url.path == '/bootstrap') {
          // Token genuinely rejected — a real signed-out state, not a blip.
          return http.Response('unauthorized', 401);
        }
        return http.Response('nope', 404);
      }),
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(api)));
    // The cached shell paints optimistically, then the background bootstrap
    // resolves to signed-out (401) and corrects the UI to sign-in. (The
    // optimistic shell-first paint is proven by the previous test, which gates
    // bootstrap; here the rejection resolves immediately, so we assert the
    // corrected end state the user lands on.)
    await tester.pumpAndSettle();
    expect(find.text('screen:signin'), findsOneWidget);
    expect(find.text('screen:shell'), findsNothing);
  });
}
