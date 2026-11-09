import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/guided_tour_controller.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/services/tour_controller.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/tour_host.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

/// The passive (self-guided) tour must go inert while a voice call is live
/// (founder, 2026-11-09): its spotlight cutout presses taps through to the
/// real control behind it, and a step anchored on the orb would land the
/// tap on the call control itself — the Nov 3 bug class (a tour tap
/// hanging / dropping the call), still reachable on this surface before
/// this fix. The driven tour already suppressed the passive one; a live
/// call now does too, and the tour resumes untouched when the call ends.
ApiClient _api() {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/bootstrap') {
      return http.Response(
        jsonEncode({
          'session_mode': 'marketing',
          'uid': 'u1',
          'livekit': {
            'token': 'tok-abc',
            'url': 'wss://example.livekit.cloud',
            'room': 'ayma-u1',
          },
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

void main() {
  setUp(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
    GuidedTourController.instance.endSession();
    TourController.instance.finish();
  });
  tearDown(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
    GuidedTourController.instance.endSession();
    TourController.instance.finish();
  });

  testWidgets('the passive tour is inert during a live call and resumes '
      'when the call ends', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      builder: (context, child) => TourHost(child: child!),
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 24,
              bottom: 24,
              child: SizedBox(
                key: TourAnchors.keyFor(TourAnchors.homeOrb),
                width: 64,
                height: 64,
              ),
            ),
          ],
        ),
      ),
    ));
    TourController.instance.start(
      const [
        TourFeature(
          featureId: 'passive_1',
          headline: 'Your orb',
          subtitle: 'Press and hold the orb to talk.',
          anchorId: TourAnchors.homeOrb,
        ),
      ],
      spotlight: false,
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // No call: the passive tour renders as always.
    expect(find.byKey(const ValueKey('root-coach-mark')), findsOneWidget);
    expect(find.text('Your orb'), findsOneWidget);

    // The call goes live: the overlay must vanish, so no press-through tap
    // can ever reach the call control behind the orb cutout.
    final transport = FakeVoiceTransport();
    final controller = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await tester.runAsync(() async {
      await controller.start();
      transport.markAgentReady();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(controller.isActive, isTrue);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.byKey(const ValueKey('root-coach-mark')), findsNothing);
    expect(find.text('Your orb'), findsNothing);

    // The call ends: the same passive tour is back, state untouched.
    await tester.runAsync(() => controller.stop());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.byKey(const ValueKey('root-coach-mark')), findsOneWidget);
    expect(find.text('Your orb'), findsOneWidget);
  });
}
