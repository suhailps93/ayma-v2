// Loader fix ROUND 2 (Scout 2290+2291 retest, Nov 2026): "Waking up Ayma…"
// NEVER surfaced in any cold start — the Flutter SplashScreen never
// rasterized a single frame (white native splash straight to chat-load, 3/3).
// The 2290 tests passed while this bug lived because they drive the splash
// widget directly: N12 (the startup DAG's destination routing) never executes
// in them. On the real path N12's optimistic cached-route go() lands
// pre-first-frame — the 800ms dwell is measured from runApp-call time while
// auth-restore latency consumes the whole budget — so the splash never mounts
// and _resolve's post-first-frame hold never runs.
//
// This test drives the REAL cold-start path: the actual N12 node action
// (StartupNodes.createDestinationRoutingNode, not a mirror) started BEFORE
// the first frame is pumped, racing the REAL SplashScreen (cached entry
// route on disk, bootstrap gated so it cannot have resolved). It fails while
// any pre-first-frame navigation exists and passes only when the first
// rasterized frame is the wake line, the cached route lands after the dwell
// via N12's own action completing promptly, and the bootstrap is still real
// work in flight — never waited on, never a faked delay.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/core/dag/startup_dag.dart';
import 'package:ayma_flutter/core/dag/startup_nodes.dart';
import 'package:ayma_flutter/models/boot_config.dart';
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

class _Marker extends StatelessWidget {
  const _Marker(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text(label));
}

void main() {
  // The first-paint signal is process-lifetime: reset it so this test never
  // inherits another file's pumped splash (no other file executes N12, so
  // this reset cannot starve anyone else's gate).
  setUp(SplashFirstPaint.resetForTest);

  testWidgets(
      'cold start through the real N12: first rasterized frame is the wake '
      'line; the cached route lands after the dwell on real work in flight',
      (tester) async {
    // A cached entry route for this uid, and a bootstrap that is GATED so it
    // cannot have resolved when the cached route lands.
    SharedPreferences.setMockInitialValues({'boot_route:u1': '/'});
    final gate = Completer<void>();
    var bootstrapStarted = false;
    final api = ApiClient(
      auth: _auth(),
      httpClient: MockClient((req) async {
        if (req.url.path == '/bootstrap') {
          bootstrapStarted = true;
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
    final router = GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(apiClient: api, auth: _auth()),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const _Marker('screen:shell'),
        ),
      ],
    );
    // The REAL destination-routing node with N10's real input shape, started
    // before the first frame is pumped — the race Scout observed on device.
    final n12done =
        StartupNodes.createDestinationRoutingNode(router: router).execute(
      DAGContext()
        ..put(
          'boot_config',
          const BootConfig(
            uid: 'u1',
            sessionMode: 'active',
            entryRoute: '/',
            cachedAtEpochMs: 0,
          ),
        ),
    );
    // Completion flag instead of a bare await: if N12 ever stalls on its
    // gate again, this fails as a clean assertion, not a hung test.
    var n12Completed = false;
    unawaited(n12done.then((_) => n12Completed = true));

    // (1) The very first rasterized frame paints the real wake line — N12
    // must not have navigated pre-first-frame.
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('Waking up Ayma…'), findsOneWidget);
    expect(find.text('screen:shell'), findsNothing);

    // (2) The dwell elapses and the cached route lands via N12's own action
    // completing promptly — not via its timeout fallback — while the wake
    // step (the bootstrap) is still real work in flight.
    await tester.pump(SplashScreen.minSplashDwell);
    await tester.pump();
    expect(find.text('screen:shell'), findsOneWidget);
    expect(n12Completed, isTrue);
    expect(bootstrapStarted, isTrue);
    expect(gate.isCompleted, isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('screen:shell'), findsOneWidget);
  });
}
