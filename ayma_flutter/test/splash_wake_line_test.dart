// Loader retest (Scout, Nov 2026): on a cold start the wing loader showed but
// "Waking up Ayma…" NEVER surfaced — the optimistic cached-route navigation
// landed before the splash had been visible for any real time (a single painted
// frame at most, skipped entirely when the startup DAG's destination routing
// won the race pre-first-frame). The splash must paint the wake line on the
// first Flutter frame and hold it for a minimum dwell; only then may the
// cached route take over (still without waiting on the bootstrap future).
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
  // Presentation is immediate unless gated (the engine never reports
  // rasterization under flutter_test) — see SplashFirstPaint.resetForTest.
  setUp(SplashFirstPaint.resetForTest);
  // The N12 (startup DAG destination routing) hold is covered by the
  // real-path test in cold_start_first_frame_test.dart, which executes the
  // actual node action against a pumped router — this file only pins the
  // splash widget's own hold below.
  testWidgets(
      'cold start: the first frame shows the wake line and holds it for the '
      'minimum dwell before the cached route takes over', (tester) async {
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

    // (1) The very first frame paints the wing loader with the wake line.
    expect(find.text('Waking up Ayma…'), findsOneWidget);
    expect(find.text('screen:shell'), findsNothing);

    // (2) With no clock time passing, the splash HOLDS — the cached route must
    // not take over before the wake line has been visible for real time.
    await tester.pump();
    await tester.pump();
    expect(find.text('Waking up Ayma…'), findsOneWidget);
    expect(find.text('screen:shell'), findsNothing);

    // (3) Once the dwell elapses, the optimistic navigation proceeds — still
    // without waiting on the (gated) bootstrap future.
    await tester.pump(SplashScreen.minSplashDwell);
    await tester.pump();
    expect(find.text('screen:shell'), findsOneWidget);

    gate.complete();
    await tester.pump(const Duration(seconds: 1));
  });
}
