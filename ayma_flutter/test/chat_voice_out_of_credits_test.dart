import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/widgets/out_of_credits.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// The exact string `VoiceSessionController._fail` uses for a capped
/// `/bootstrap` response — kept as a literal here (rather than importing a
/// private constant) so the test pins the real, reported wording.
const _kCappedMessage =
    'Out of credits — tap Upgrade to use voice.';

/// A [VoiceSessionController] that drives the *real* phase-transition
/// sequence a live capped call goes through (idle -> connecting -> error),
/// without a real `/bootstrap`/LiveKit round trip. This mirrors
/// `main_shell_screen_test.dart`'s `_FakeVoice`, extended with the
/// `cappedError`/`errorMessage` state `OutOfCreditsBanner` actually reads.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  String? _errorMessage;
  bool _cappedError = false;

  @override
  VoiceSessionPhase get phase => _phase;

  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get cappedError => _cappedError;

  @override
  bool get isActive =>
      _phase == VoiceSessionPhase.connecting ||
      _phase == VoiceSessionPhase.waking ||
      _phase == VoiceSessionPhase.live;

  @override
  bool get isListening => _phase == VoiceSessionPhase.live;

  /// Mirrors the real `start()` -> `bootstrap()` -> `_fail()` sequence: the
  /// UI sees `connecting` first (a real notifyListeners + rebuild), then
  /// lands on the capped `error` phase — not a single static jump straight
  /// to the end state.
  @override
  Future<void> start() async {
    _phase = VoiceSessionPhase.connecting;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _cappedError = true;
    _errorMessage = _kCappedMessage;
    _phase = VoiceSessionPhase.error;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _phase = VoiceSessionPhase.idle;
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

Future<void> _tapMicIntoCappedError(WidgetTester tester, _FakeVoice voice) async {
  // Real user gesture: tap the composer's mic button, exactly like the
  // founder did on-device, rather than jumping the controller straight to
  // a static error state.
  await tester.tap(find.byIcon(Icons.mic_none_rounded));
  await tester.pump(); // commits `connecting`
  await tester.pump(const Duration(milliseconds: 1)); // the delayed() timer fires
  await tester.pump(); // commits `error` + the capped banner

  expect(voice.phase, VoiceSessionPhase.error);
  expect(voice.cappedError, isTrue);
}

void main() {
  testWidgets(
      'tapping the mic on a capped account renders the out-of-credits '
      'banner as one normal paragraph, not one character per line',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = await _historyOnlyApi();
    final voice = _FakeVoice();

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: api, voiceController: voice),
    ));
    await tester.pumpAndSettle();

    await _tapMicIntoCappedError(tester, voice);

    // `_toggleVoice` also raises a toast with the same wording, so target
    // the banner specifically (not the incidental toast) rather than a bare
    // `find.text`, which would match both.
    final textFinder = find.descendant(
      of: find.byType(OutOfCreditsBanner),
      matching: find.text(_kCappedMessage),
    );
    // Renders as one Text widget whose plain text is the *whole* sentence —
    // if this were split one character per line (each glyph its own
    // Text/span), no single widget would ever match the full string.
    expect(textFinder, findsOneWidget);

    // A short sentence at 1080-wide should take a handful of lines at most —
    // nowhere near the height a one-char-per-line render would produce.
    final size = tester.getSize(textFinder);
    expect(size.height, lessThan(150));
  });

  testWidgets(
      'same scenario at the founder\'s actual connected-device screen '
      'metrics (Pixel 10 Pro Fold outer display: 1080x2364 @ 390dpi, via '
      '`adb shell wm size`/`wm density`) — the suite\'s usual 1080-logical-px '
      'convention is tablet-wide and could mask a narrow-phone-only collapse',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2364);
    tester.view.devicePixelRatio = 390 / 160;
    addTearDown(tester.view.reset);

    final api = await _historyOnlyApi();
    final voice = _FakeVoice();

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: api, voiceController: voice),
    ));
    await tester.pumpAndSettle();

    await _tapMicIntoCappedError(tester, voice);

    final textFinder = find.descendant(
      of: find.byType(OutOfCreditsBanner),
      matching: find.text(_kCappedMessage),
    );
    expect(textFinder, findsOneWidget);

    // At a real ~443-logical-px phone width this sentence wraps to a few
    // lines; a one-char-per-line collapse would instead produce ~55 lines
    // (one per glyph) and blow well past this.
    final size = tester.getSize(textFinder);
    expect(size.height, lessThan(150));
  });
}
