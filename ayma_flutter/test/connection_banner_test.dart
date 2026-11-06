import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/connection_banner.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _exploreApi() {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        return http.Response(jsonEncode({'cards': []}), 200);
      }
      return http.Response('no', 404);
    }),
  );
}

/// Mirrors main.dart: the shell banner wraps the routed pages in
/// MaterialApp.router's builder, here over Explore — a page that never had a
/// per-screen freshness strip.
Widget _shell(ConnectionHeartbeat hb) {
  final router = GoRouter(
    initialLocation: '/explore',
    routes: [
      GoRoute(
        path: '/explore',
        builder: (_, __) => ExploreScreen(apiClient: _exploreApi()),
      ),
    ],
  );
  addTearDown(router.dispose);
  return MaterialApp.router(
    routerConfig: router,
    theme: AymaTheme.light,
    builder: (context, child) =>
        ConnectionBanner(heartbeat: hb, child: child ?? const SizedBox()),
  );
}

/// Scripted heartbeat: [script] outcomes in order, then repeats the last one
/// so the banner's start-up probe can never run the script dry.
ConnectionHeartbeat _scripted(List<ProbeOutcome> script) {
  var i = 0;
  return ConnectionHeartbeat(
    probe: () async => script[i < script.length ? i++ : script.length - 1],
    connectivityChanges: const Stream.empty(),
  );
}

Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  testWidgets('ok state renders no banner over Explore', (tester) async {
    final hb = _scripted([ProbeOutcome.good]);
    await tester.pumpWidget(_shell(hb));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ExploreScreen), findsOneWidget);
    expect(find.text('Offline — showing saved data'), findsNothing);
    expect(find.text('Weak connection — showing saved data'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('offline state renders the offline banner over Explore',
      (tester) async {
    final hb = _scripted([ProbeOutcome.failure, ProbeOutcome.failure]);
    // Drive to offline before the banner mounts its start-up probe.
    await hb.probeNow();
    await hb.probeNow();
    expect(hb.state, ConnectionQuality.offline);

    await tester.pumpWidget(_shell(hb));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ExploreScreen), findsOneWidget);
    expect(find.text('Offline — showing saved data'), findsOneWidget);
    expect(find.text('Weak connection — showing saved data'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('weak state renders the weak banner over Explore', (tester) async {
    final hb = _scripted([ProbeOutcome.slow, ProbeOutcome.slow]);
    await hb.probeNow();
    await hb.probeNow();
    expect(hb.state, ConnectionQuality.weak);

    await tester.pumpWidget(_shell(hb));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Weak connection — showing saved data'), findsOneWidget);
    expect(find.text('Offline — showing saved data'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('recovery clears the banner without touching the page',
      (tester) async {
    final hb = _scripted([
      ProbeOutcome.failure,
      ProbeOutcome.failure,
      // The banner's start-up probe consumes one outcome after mounting.
      ProbeOutcome.failure,
      ProbeOutcome.good,
      ProbeOutcome.good,
    ]);
    await hb.probeNow();
    await hb.probeNow();
    expect(hb.state, ConnectionQuality.offline);

    await tester.pumpWidget(_shell(hb));
    await tester.pump(const Duration(milliseconds: 100));
    // The banner's start-up probe must land before the scripted recovery.
    for (var i = 0; i < 100 && hb.probeCount < 3; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(hb.probeCount, 3);
    expect(find.text('Offline — showing saved data'), findsOneWidget);

    // Two consecutive good probes recover to ok and the banner goes away.
    await hb.probeNow();
    await hb.probeNow();
    await tester.pump();
    expect(hb.state, ConnectionQuality.ok);
    expect(find.text('Offline — showing saved data'), findsNothing);
    expect(find.text('Weak connection — showing saved data'), findsNothing);
    expect(find.byType(ExploreScreen), findsOneWidget);
    await _unmount(tester);
  });
}
