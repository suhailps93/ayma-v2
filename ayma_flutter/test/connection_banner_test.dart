import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/connection_banner.dart';
import 'package:ayma_flutter/widgets/freshness_indicator.dart';
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
    final hb = _scripted([
      ProbeOutcome.failure,
      ProbeOutcome.failure,
      ProbeOutcome.failure,
    ]);
    // Drive to offline before the banner mounts its start-up probe.
    await hb.probeNow();
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
      ProbeOutcome.failure,
      // The banner's start-up probe consumes one outcome after mounting.
      ProbeOutcome.failure,
      ProbeOutcome.good,
      ProbeOutcome.good,
    ]);
    await hb.probeNow();
    await hb.probeNow();
    await hb.probeNow();
    expect(hb.state, ConnectionQuality.offline);

    await tester.pumpWidget(_shell(hb));
    await tester.pump(const Duration(milliseconds: 100));
    // The banner's start-up probe must land before the scripted recovery.
    for (var i = 0; i < 100 && hb.probeCount < 4; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(hb.probeCount, 4);
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

  // V7 (brief): the weak strip and the offline strip share identical 16/6
  // padding + 14 icon + 12 text by design ("same treatment"), so they must
  // render the SAME content height — otherwise the two strips would visibly
  // jump when connection quality flaps weak <-> offline. (R7 holds this shared
  // geometry as a pair; this test guards that it stays matched here.)
  testWidgets('weak and offline strips render the same height', (tester) async {
    double stripRowHeight(String label) => tester
        .getSize(find.ancestor(of: find.text(label), matching: find.byType(Row))
            .first)
        .height;

    final offlineHb = _scripted([
      ProbeOutcome.failure,
      ProbeOutcome.failure,
      ProbeOutcome.failure,
    ]);
    await offlineHb.probeNow();
    await offlineHb.probeNow();
    await offlineHb.probeNow();
    expect(offlineHb.state, ConnectionQuality.offline);
    await tester.pumpWidget(_shell(offlineHb));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Offline — showing saved data'), findsOneWidget);
    final offlineHeight = stripRowHeight('Offline — showing saved data');
    await _unmount(tester);

    final weakHb = _scripted([ProbeOutcome.slow, ProbeOutcome.slow]);
    await weakHb.probeNow();
    await weakHb.probeNow();
    expect(weakHb.state, ConnectionQuality.weak);
    await tester.pumpWidget(_shell(weakHb));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Weak connection — showing saved data'), findsOneWidget);
    final weakHeight = stripRowHeight('Weak connection — showing saved data');
    await _unmount(tester);

    expect(weakHeight, moreOrLessEquals(offlineHeight, epsilon: 0.01),
        reason: 'weak strip $weakHeight must match offline strip '
            '$offlineHeight');
  });

  // Regression (founder report, Nov 5 2026): with the banner up, every page
  // showed a dead band of empty space under the strip. The strip consumes
  // the status-bar inset with its own SafeArea; the page below then applied
  // the SAME inset again through its own SafeArea, because the child
  // subtree still inherited the full top padding. The banner must remove
  // the top padding for its child so the inset is applied exactly once.
  group('status-bar inset is applied exactly once', () {
    const statusBarInset = 24.0;

    Widget probeShell(ConnectionHeartbeat hb, void Function(EdgeInsets) onSee) {
      return MaterialApp(
        home: ConnectionBanner(
          heartbeat: hb,
          child: Builder(
            builder: (context) {
              onSee(MediaQuery.paddingOf(context));
              return const Scaffold(
                body: SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      key: Key('pageTopMarker'),
                      width: 20,
                      height: 20,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    testWidgets(
      'offline: child sees no top padding; page sits flush under the strip',
      (tester) async {
        tester.view.padding = const FakeViewPadding(top: statusBarInset * 3.0);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        final hb = _scripted([
          ProbeOutcome.failure,
          ProbeOutcome.failure,
          ProbeOutcome.failure,
        ]);
        await hb.probeNow();
        await hb.probeNow();
        await hb.probeNow();
        expect(hb.state, ConnectionQuality.offline);

        EdgeInsets? seen;
        await tester.pumpWidget(probeShell(hb, (p) => seen = p));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Offline — showing saved data'), findsOneWidget);
        // The strip already paid the status-bar inset; the child subtree
        // must not inherit it a second time.
        expect(seen?.top, 0);
        // Geometry: the page SafeArea content starts exactly at the strip
        // bottom edge — no dead band.
        final stripBottom = tester
            .getRect(find.byType(FreshnessIndicator))
            .bottom;
        final pageTop = tester
            .getRect(find.byKey(const Key('pageTopMarker')))
            .top;
        expect(pageTop, stripBottom);
        await _unmount(tester);
      },
    );

    testWidgets('weak: child sees no top padding', (tester) async {
      tester.view.padding = const FakeViewPadding(top: statusBarInset * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final hb = _scripted([ProbeOutcome.slow, ProbeOutcome.slow]);
      await hb.probeNow();
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.weak);

      EdgeInsets? seen;
      await tester.pumpWidget(probeShell(hb, (p) => seen = p));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Weak connection — showing saved data'), findsOneWidget);
      expect(seen?.top, 0);
      await _unmount(tester);
    });

    testWidgets('ok: no banner, child keeps the full top padding (unchanged)', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: statusBarInset * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final hb = _scripted([ProbeOutcome.good]);

      EdgeInsets? seen;
      await tester.pumpWidget(probeShell(hb, (p) => seen = p));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Offline — showing saved data'), findsNothing);
      expect(find.text('Weak connection — showing saved data'), findsNothing);
      expect(seen?.top, statusBarInset);
      await _unmount(tester);
    });
  });
}
