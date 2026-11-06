import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/voice_call_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A [VoiceSessionController] whose lifecycle is driven entirely by test
/// code (`setPhase`/`setSpeaking`) instead of a real `/bootstrap`/LiveKit
/// round trip — same pattern as `chat_voice_out_of_credits_test.dart`'s
/// `_FakeVoice`, extended to reach a real `live` phase (that test only ever
/// reaches `error`).
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;
  bool _fakeSpeaking = false;
  bool _fakeMuted = false;
  int toggleMuteCalls = 0;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get agentSpeaking => _fakeSpeaking;

  @override
  bool get muted => _fakeMuted;

  bool _fakeQuiet = false;
  int unmuteAymaCalls = 0;

  @override
  Future<void> unmuteAyma() async {
    unmuteAymaCalls += 1;
  }

  @override
  bool get aymaQuiet => _fakeQuiet;

  void setQuiet(bool quiet) {
    _fakeQuiet = quiet;
    notifyListeners();
  }

  @override
  bool get isActive =>
      _fakePhase == VoiceSessionPhase.connecting ||
      _fakePhase == VoiceSessionPhase.waking ||
      _fakePhase == VoiceSessionPhase.live;

  @override
  bool get isListening => _fakePhase == VoiceSessionPhase.live;

  bool _fakeResponded = false;

  /// Mirrors the real getter: live with no first reply yet is still waiting.
  @override
  bool get awaitingFirstResponse =>
      _fakePhase == VoiceSessionPhase.live && !_fakeResponded;

  /// The opener/first reply landed — the status flips to "Listening…".
  void setResponded() {
    _fakeResponded = true;
    notifyListeners();
  }

  void setPhase(VoiceSessionPhase phase) {
    _fakePhase = phase;
    notifyListeners();
  }

  void setSpeaking(bool speaking) {
    _fakeSpeaking = speaking;
    notifyListeners();
  }

  /// Mirrors the real `start()`'s two-step `connecting` -> `live` sequence
  /// (a real notifyListeners + rebuild for each), without ever touching the
  /// network.
  @override
  Future<void> start({bool forceRelayFirst = false}) async {
    setPhase(VoiceSessionPhase.connecting);
    await Future<void>.delayed(Duration.zero);
    setPhase(VoiceSessionPhase.live);
  }

  @override
  Future<void> stop() async {
    setPhase(VoiceSessionPhase.idle);
  }

  /// Mirrors the real `toggleMute()`'s contract — a no-op unless live, flips
  /// [muted], notifies, and never touches [phase] — without the LiveKit
  /// transport underneath.
  @override
  Future<void> toggleMute() async {
    toggleMuteCalls += 1;
    if (_fakePhase != VoiceSessionPhase.live) return;
    _fakeMuted = !_fakeMuted;
    notifyListeners();
  }
}

Future<ApiClient> _historyOnlyApi() async {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') {
      return http.Response(
        jsonEncode({'messages': <dynamic>[], 'next_before': null}),
        200,
        headers: _jsonUtf8,
      );
    }
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  group('VoiceCallScreen layout', () {
    testWidgets(
        'a live call renders a large centered orb, a close button, and '
        'nothing else — no transcript, no composer', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()
        ..setPhase(VoiceSessionPhase.live)
        ..setResponded();

      await tester.pumpWidget(MaterialApp(
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      // The orb: present, and sized like an immersive centerpiece (spec's
      // "large" breakpoint is >= 160 logical px) rather than the composer's
      // modest inline treatment.
      final orbFinder = find.byKey(const Key('voiceCallOrb'));
      expect(orbFinder, findsOneWidget);
      final orb = tester.widget<AymaOrb>(orbFinder);
      expect(orb.size, greaterThanOrEqualTo(160));
      expect(orb.state, AymaOrbState.listening);

      // Roughly centered horizontally in the viewport.
      final screenWidth = tester.view.physicalSize.width /
          tester.view.devicePixelRatio;
      final orbCenter = tester.getCenter(orbFinder);
      expect((orbCenter.dx - screenWidth / 2).abs(), lessThan(2));

      // A close affordance up top.
      expect(find.byIcon(Icons.close), findsOneWidget);
      final closeCenter = tester.getCenter(find.byIcon(Icons.close));
      expect(closeCenter.dy, lessThan(orbCenter.dy));

      // No transcript / composer leaking into this surface.
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);

      // Status label reflects the live, unmuted, not-speaking state.
      expect(find.text('Listening…'), findsOneWidget);
    });

    testWidgets(
        'a live call with no first reply yet reads "Connecting…", flipping '
        'to "Listening…" once Ayma responds', (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);

      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();

      // Live, but the opener is still in flight: honest wait state, never a
      // fake "Listening…".
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);

      voice.setResponded();
      await tester.pump();

      expect(find.text('Listening…'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('shows the "Ayma is quiet" chip only while she is muted',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      final chipText = find.textContaining('Ayma is quiet', findRichText: true);

      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();
      expect(chipText, findsNothing);

      voice.setQuiet(true);
      await tester.pump();
      expect(chipText, findsOneWidget);
      expect(find.bySemanticsLabel('Unmute Ayma'), findsOneWidget);

      await tester.tap(find.byKey(const Key('aymaQuietUnmute')));
      await tester.pump();
      expect(voice.unmuteAymaCalls, 1);

      voice.setQuiet(false);
      await tester.pump();
      expect(chipText, findsNothing);
    });

    testWidgets('reflects Ayma speaking with the speaking orb state',
        (tester) async {
      final voice = _FakeVoice()
        ..setPhase(VoiceSessionPhase.live)
        ..setSpeaking(true);

      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();

      final orb = tester.widget<AymaOrb>(find.byKey(const Key('voiceCallOrb')));
      expect(orb.state, AymaOrbState.speaking);
      expect(find.text('Ayma is speaking…'), findsOneWidget);
    });

    testWidgets(
        'connecting/waking render the thinking orb state with the right '
        'status label', (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.connecting);

      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();

      expect(
        tester.widget<AymaOrb>(find.byKey(const Key('voiceCallOrb'))).state,
        AymaOrbState.thinking,
      );
      expect(find.text('Connecting…'), findsOneWidget);

      voice.setPhase(VoiceSessionPhase.waking);
      await tester.pump();

      expect(
        tester.widget<AymaOrb>(find.byKey(const Key('voiceCallOrb'))).state,
        AymaOrbState.thinking,
      );
      expect(find.text('Waking Ayma…'), findsOneWidget);
    });

    testWidgets('tapping close pops back to whatever was underneath',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VoiceCallScreen(voice: voice),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      // Not `pumpAndSettle`: the orb's own internal animation controller
      // repeats forever while it's mounted, so a settle here would never
      // terminate (matches `ayma_orb_test.dart`'s own convention of explicit
      // durations instead). One zero-duration pump lands the push; a second,
      // non-zero one lets the route's entrance transition actually progress
      // — Flutter's `HeroController` holds an incoming route offstage (and
      // so invisible to `find.byKey`/`byType`) for as long as its transition
      // animation sits at exactly 0.0.
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('voiceCallOrb')), findsOneWidget);

      // The push's own entrance transition is still sliding the new page in
      // at 50ms — real enough to reveal the orb to a *finder* (which ignores
      // paint transforms), but the close button's actual on-screen position
      // is still off to the side, so a *tap* there would miss. Let the
      // transition finish (its default duration is 300ms) before tapping it.
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.close));
      // Popping *is* safe to settle on: once the (finite) pop transition
      // finishes, `VoiceCallScreen` — and its orb ticker — is disposed, so
      // nothing is left requesting frames.
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('voiceCallOrb')), findsNothing);
      expect(find.text('open'), findsOneWidget);
      // Closing the view must never end the call.
      expect(voice.phase, VoiceSessionPhase.live);
    });
  });

  group('VoiceCallScreen mute button', () {
    testWidgets('renders round mic toggle at the bottom center, unmuted',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();

      final button = find.byKey(const Key('voiceCallMuteButton'));
      expect(button, findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_rounded), findsNothing);

      // Bottom center: horizontally centered, below the orb, in the lower
      // band of the screen.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final buttonCenter = tester.getCenter(button);
      final orbCenter =
          tester.getCenter(find.byKey(const Key('voiceCallOrb')));
      expect((buttonCenter.dx - screen.width / 2).abs(), lessThan(2));
      expect(buttonCenter.dy, greaterThan(orbCenter.dy));
      expect(buttonCenter.dy, greaterThan(screen.height * 0.8));
    });

    testWidgets(
        'tapping toggles the controller mic state both ways without ending '
        'the call', (tester) async {
      final voice = _FakeVoice()
        ..setPhase(VoiceSessionPhase.live)
        ..setResponded();
      await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(voice: voice)));
      await tester.pump();

      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump();

      expect(voice.toggleMuteCalls, 1);
      expect(voice.muted, isTrue);
      // The button reflects the actual controller state, and the status
      // label reads Muted.
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsNothing);
      expect(find.text('Muted'), findsOneWidget);
      // Muting never ends or disrupts the call, and never closes this view.
      expect(voice.phase, VoiceSessionPhase.live);
      expect(find.byKey(const Key('voiceCallOrb')), findsOneWidget);

      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump();

      expect(voice.muted, isFalse);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);
      expect(voice.phase, VoiceSessionPhase.live);
    });

    testWidgets('mute state survives closing and reopening the screen '
        'mid-call (it lives on the controller)', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VoiceCallScreen(voice: voice),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      // Open, let the entrance transition finish (see the layout group's
      // notes on why these explicit pumps instead of pumpAndSettle).
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump();
      expect(voice.muted, isTrue);

      // Close the view — the call (and its mute state) must survive.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voiceCallMuteButton')), findsNothing);
      expect(voice.phase, VoiceSessionPhase.live);
      expect(voice.muted, isTrue);

      // Reopen: the button reflects the still-muted controller state.
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
      expect(find.text('Muted'), findsOneWidget);
    });
  });

  group('ChatScreen voice entry/re-entry', () {
    testWidgets(
        'tapping the composer mic only starts the session inline — it never '
        'pushes the full-screen voice view', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = await _historyOnlyApi();
      final voice = _FakeVoice();

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(apiClient: api, voiceController: voice),
      ));
      await tester.pumpAndSettle();

      // No session yet: no full-screen entry point in the header either.
      expect(
        find.byKey(const Key('chatVoiceFullscreenButton')),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      // Same async cadence as `chat_voice_out_of_credits_test.dart`: a
      // zero-duration pump to commit `connecting`, a 1ms one to let the fake
      // `Future.delayed(Duration.zero)` in `start()` fire, then a final
      // zero-duration one to render `live`. No `pumpAndSettle` anywhere in
      // this flow — the composer's voice-mode wave animation loops forever
      // while the call is up.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(voice.phase, VoiceSessionPhase.live);
      // Founder revision (2026-09-26): the mic no longer auto-opens the
      // full-screen orb view — we stay on the chat screen, composer morphed
      // into the inline call bar.
      expect(find.byKey(const Key('voiceCallOrb')), findsNothing);
      expect(find.byType(VoiceCallScreen), findsNothing);
      // The composer's inline call bar (its End button) is what's on screen
      // now, not the full-screen orb. (`mic_none_rounded` can't distinguish
      // the states here — the call bar's own inline mute button reuses it.)
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    });

    testWidgets(
        'the header full-screen button appears only while a session is live '
        'and opens the full-screen voice view', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = await _historyOnlyApi();
      final voice = _FakeVoice();

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(apiClient: api, voiceController: voice),
      ));
      await tester.pumpAndSettle();

      final fullscreenButton =
          find.byKey(const Key('chatVoiceFullscreenButton'));
      expect(fullscreenButton, findsNothing);

      // Start a call from the mic; the button appears top-right, above the
      // transcript, without any route change having happened.
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(voice.phase, VoiceSessionPhase.live);
      expect(fullscreenButton, findsOneWidget);
      expect(find.byType(VoiceCallScreen), findsNothing);
      // Top-right of the chat screen: in the header band, right half.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final buttonCenter = tester.getCenter(fullscreenButton);
      expect(buttonCenter.dx, greaterThan(screen.width / 2));
      expect(buttonCenter.dy, lessThan(screen.height * 0.15));

      // Tapping it opens the full-screen view over the same live session.
      await tester.tap(fullscreenButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('voiceCallOrb')), findsOneWidget);
      expect(
        tester.widget<AymaOrb>(find.byKey(const Key('voiceCallOrb'))).state,
        AymaOrbState.listening,
      );
      expect(voice.phase, VoiceSessionPhase.live);

      // Ending the call (after closing the view) hides the button again.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.close));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await voice.stop();
      await tester.pump();
      expect(fullscreenButton, findsNothing);
    });

    testWidgets(
        'closing the full-screen view returns to the inline call bar, '
        'which can re-open it', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = await _historyOnlyApi();
      final voice = _FakeVoice();

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(apiClient: api, voiceController: voice),
      ));
      await tester.pumpAndSettle();

      // Start the call (inline), then go full-screen through the header's
      // expand button — the mic itself no longer pushes the view.
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(voice.phase, VoiceSessionPhase.live);
      // The opener landed, so the inline bar reads "Listening…" (a live call
      // with no first reply yet honestly reads "Connecting…" instead).
      voice.setResponded();
      await tester.pump();

      await tester.tap(find.byKey(const Key('chatVoiceFullscreenButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('voiceCallOrb')), findsOneWidget);

      // Let the push's own entrance transition finish before tapping
      // anything on the pushed page — mid-slide, the close button's real
      // on-screen position isn't where a finder-only check would suggest
      // (see the identical note in the `VoiceCallScreen layout` group).
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.close));
      // Not `pumpAndSettle`: the call is still live once we're back on
      // `ChatScreen`, so the composer's own voice-mode wave animation keeps
      // repeating (`ChatComposer._syncTicker` only lets it stop once the
      // mode is back to `text`) — same infinite-ticker hazard as the orb.
      // Pumped in several smaller steps rather than one big jump — the pop
      // transition's own removal only actually lands a bit past its nominal
      // 300ms duration, and empirically needs to be pumped *through*
      // (measured directly against this exact scenario), not skipped past in
      // one leap.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Back on the chat screen; the call is still live, so the composer
      // shows its inline bar (mute/stop), not the idle mic button.
      expect(find.byKey(const Key('voiceCallOrb')), findsNothing);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

      // Tapping the inline bar's status label re-opens the full-screen view
      // without touching the (already-live) session.
      await tester.tap(find.text('Listening…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('voiceCallOrb')), findsOneWidget);
      expect(voice.phase, VoiceSessionPhase.live);
    });
  });
}
