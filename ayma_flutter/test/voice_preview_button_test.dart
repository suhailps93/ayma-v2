import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_preview_player.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/voice_engine_control.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Founder feedback 2026-11-07 (staging feedback IooiV9lbaai8xD64WCWi):
/// "in the voice section there is no way to pre-play what the voice would
/// look like before actually selecting that… it should play a predefined
/// [sample], and [the user] should be able to do that even if Emma is
/// active on voice without breaking the voice, similar to how [a] voice
/// message [plays]".
///
/// The backend sample endpoint (GET /voice/preview/{name}), the API client
/// method and the preview player all existed, but the Voice section never
/// wired them up: no preview affordance anywhere in the picker. These tests
/// pin the wiring: a play/stop button beside the VOICE dropdown that plays
/// the dropdown's current (unsaved) choice through the standalone preview
/// player, never touches the live voice session, and fails honestly for a
/// voice with no recorded sample.

Map<String, dynamic> _catalog() => {
  'modes': ['realtime', 'cascade'],
  'source': 'livekit',
  'realtime_models': [
    {
      'id': 'gemini-live',
      'label': 'Gemini Live (native audio)',
      'provider': 'gemini',
      'available': true,
      'requires_secret': '',
      'supports_accent': true,
      'voices': [
        {'id': 'Aoede', 'label': 'Aoede', 'description': 'warm'},
        {'id': 'Charon', 'label': 'Charon', 'description': 'deep'},
      ],
      'languages': [
        {'code': '', 'label': 'Default (English)'},
        {'code': 'ml-IN', 'label': 'Malayalam'},
      ],
    },
  ],
  'brains': [
    {
      'id': 'google/gemini-3.7-flash',
      'label': 'google/gemini-3.7-flash',
      'provider': 'google',
      'available': true,
    },
  ],
  'stt': [
    {
      'id': 'deepgram/nova-3',
      'label': 'deepgram/nova-3',
      'provider': 'deepgram',
      'available': true,
    },
  ],
  'tts': [
    {
      'id': 'inworld/inworld-tts-1',
      'label': 'inworld/inworld-tts-1',
      'provider': 'inworld',
      'available': true,
      'supports_accent': false,
      'voices': [
        {'id': '', 'label': 'Default (Ashley)'},
        {'id': 'Ashley', 'label': 'Ashley', 'description': 'bright'},
        {'id': 'Hades', 'label': 'Hades', 'description': 'deep'},
      ],
      'languages': [
        {'code': '', 'label': 'Default (English)'},
        {'code': 'es-ES', 'label': 'Spanish'},
      ],
    },
    {
      'id': 'fishaudio/s2.1-pro',
      'label': 'fishaudio/s2.1-pro',
      'provider': 'fishaudio',
      'available': true,
      'supports_accent': false,
      'voices': [
        {'id': '', 'label': 'Default voice'},
        {'id': 'speaker1', 'label': 'Speaker 1'},
      ],
      'languages': [
        {'code': '', 'label': 'Default (English)'},
      ],
    },
  ],
  'default': {
    'mode': 'realtime',
    'realtime_model_id': 'gemini-live',
    'brain_id': 'google/gemini-3.7-flash',
    'stt_id': 'deepgram/nova-3',
    'tts_id': 'inworld/inworld-tts-1',
  },
  'current': {
    'mode': 'realtime',
    'realtime_model_id': 'gemini-live',
    'brain_id': 'google/gemini-3.7-flash',
    'stt_id': 'deepgram/nova-3',
    'tts_id': 'inworld/inworld-tts-1',
    'voice_id': 'Aoede',
    'language_code': '',
    'accent': '',
  },
};

final List<Map<String, dynamic>> _posted = [];

/// Only the Gemini presets have recorded samples on the server (cached
/// clips); any other voice name 404s, exactly like production.
ApiClient _api() {
  _posted.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(
        jsonEncode(_catalog()),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (req.url.path == '/voice/preference') {
      _posted.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({'ok': true}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (req.url.path.startsWith('/voice/preview/')) {
      final name = Uri.decodeComponent(req.url.pathSegments.last);
      if (name == 'Aoede' || name == 'Charon' || name == 'Ashley') {
        return http.Response(
          jsonEncode({'url': 'https://example.test/$name.wav'}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('no preview for $name', 404);
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(Widget child) => MaterialApp(
  theme: AymaTheme.light,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Finder _previewButton() => find.byKey(const ValueKey('voice-preview-button'));

void main() {
  testWidgets('preview button plays a sample of the selected voice, '
      'and tapping again stops it — nothing is saved', (tester) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    expect(_previewButton(), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    // The sample for the currently shown voice (Aoede) was fetched + played.
    expect(player.played, ['https://example.test/Aoede.wav']);
    // Previewing is not selecting: no preference save was posted.
    expect(_posted, isEmpty);
    // The button now offers stop.
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();
    expect(player.stopCalls, greaterThanOrEqualTo(1));
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('preview follows the dropdown choice BEFORE anything is saved', (
    tester,
  ) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    // Change the dropdown to Charon (a local, unsaved choice).
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charon — deep').last);
    await tester.pumpAndSettle();

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    expect(player.played, ['https://example.test/Charon.wav']);
    expect(_posted, isEmpty); // still nothing saved
  });

  testWidgets('preview leaves a live voice call completely alone', (
    tester,
  ) async {
    final voice = _FakeVoice();
    VoiceSessionController.active = voice;
    addTearDown(() => VoiceSessionController.active = null);

    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    expect(player.played, ['https://example.test/Aoede.wav']);
    // The live session was not stopped, reconnected or nudged in any way.
    expect(voice.stopCalls, 0);
    expect(voice.reconnectCalls, 0);
    expect(voice.notifyCalls, 0);
  });

  testWidgets('changing the voice while a preview plays stops the preview', (
    tester,
  ) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();
    expect(player.played, hasLength(1));
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charon — deep').last);
    await tester.pumpAndSettle();

    expect(player.stopCalls, greaterThanOrEqualTo(1));
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('a voice with no recorded sample fails honestly, plays nothing', (
    tester,
  ) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    // Cascade mode → the Inworld voices.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hades — deep').last);
    await tester.pumpAndSettle();

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    expect(player.played, isEmpty);
    expect(
      find.text('No preview recorded for this voice yet.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('preview tap-again while loading cancels and stops playback', (
    tester,
  ) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    // Tap play
    await tester.tap(_previewButton());
    // Pump one frame so the request begins and UI marks busy
    await tester.pump();

    // Tap again immediately (e.g. at +1s while loading / playing)
    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    // Stop must have been called on the player
    expect(player.stopCalls, greaterThanOrEqualTo(1));
    // Icon must be back to play
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
  });

  testWidgets('the preview icon auto-reverts to play when playback ends', (
    tester,
  ) async {
    final player = _FakePreviewPlayer();
    await tester.pumpWidget(
      _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);

    await tester.tap(_previewButton());
    await tester.pumpAndSettle();

    // Playing: shows stop icon
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    // Audio finishes playing naturally (sample clip ends)
    player.onComplete?.call();
    await tester.pump();

    // Button icon must auto-revert to play outline without requiring a manual tap
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
  });

  testWidgets(
    'Default voice entry shows an enabled preview button whose tap plays and second tap stops',
    (tester) async {
      final player = _FakePreviewPlayer();
      await tester.pumpWidget(
        _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
      );
      await tester.pumpAndSettle();

      // Switch to Cascade mode
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
      await tester.pumpAndSettle();

      // For inworld-tts-1, default voice is Default (Ashley) (id: "")
      // Neither helper text nor fallback note is displayed anywhere
      expect(
        find.textContaining('Hear a short sample of the voice'),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);

      // Verify button is enabled
      final btn = tester.widget<IconButton>(_previewButton());
      expect(btn.onPressed, isNotNull);

      // Tap preview on Default voice entry
      await tester.tap(_previewButton());
      await tester.pumpAndSettle();

      // Default voice resolved to Ashley and played
      expect(player.played, ['https://example.test/Ashley.wav']);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

      // Second tap stops playback
      await tester.tap(_previewButton());
      await tester.pumpAndSettle();
      expect(player.stopCalls, greaterThanOrEqualTo(1));
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    },
  );

  testWidgets(
    'Default voice entry with unidentified default leaves button enabled and tap shows honest toast',
    (tester) async {
      final player = _FakePreviewPlayer();
      await tester.pumpWidget(
        _host(VoiceEngineControl(api: _api(), previewPlayer: player)),
      );
      await tester.pumpAndSettle();

      // Switch to Cascade mode
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
      await tester.pumpAndSettle();

      // Switch TTS to fishaudio/s2.1-pro
      await tester.tap(
        find.widgetWithText(DropdownButton<String>, 'inworld/inworld-tts-1'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('fishaudio/s2.1-pro').last);
      await tester.pumpAndSettle();

      // The voice dropdown now has Default voice (unidentified vendor default)
      final btn = tester.widget<IconButton>(_previewButton());
      expect(btn.onPressed, isNotNull);

      await tester.tap(_previewButton());
      await tester.pumpAndSettle();

      expect(player.played, isEmpty);
      expect(
        find.text('No preview recorded for this voice yet.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    },
  );
}

/// Records preview playback instead of touching platform audio.
class _FakePreviewPlayer implements VoicePreviewPlayer {
  final List<String> played = [];
  int stopCalls = 0;
  bool disposed = false;

  @override
  VoidCallback? onComplete;

  @override
  Future<void> play(String url) async {
    played.add(url);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// A live call stand-in: any stop / reconnect / accent nudge the preview
/// might (wrongly) trigger is counted here.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  int stopCalls = 0;
  int reconnectCalls = 0;
  int notifyCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
  }

  @override
  Future<bool> notifyVoiceAccentChanged({
    required String accent,
    required String language,
  }) async {
    notifyCalls++;
    return true;
  }
}
