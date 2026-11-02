import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/voice_engine_control.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A catalog with two realtime models and a cascade TTS, each with distinct
/// voices, so a test can prove the voice list tracks the selected component.
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
        {
          'id': 'openai-realtime',
          'label': 'OpenAI Realtime',
          'provider': 'openai',
          'available': false,
          'requires_secret': 'OPENAI_API_KEY',
          'voices': [
            {'id': 'alloy', 'label': 'Alloy'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'brains': [
        {'id': 'meta-muse-spark', 'label': 'Meta Muse Spark', 'provider': 'meta', 'available': true},
        {'id': 'google/gemini-3.7-flash', 'label': 'google/gemini-3.7-flash', 'provider': 'google', 'available': true},
      ],
      'stt': [
        {'id': 'deepgram/nova-3', 'label': 'deepgram/nova-3', 'provider': 'deepgram', 'available': true},
      ],
      'tts': [
        {
          'id': 'inworld/inworld-tts-1',
          'label': 'inworld/inworld-tts-1',
          'provider': 'inworld',
          'available': true,
          'supports_accent': false,
          'voices': [
            {'id': '', 'label': 'Default voice'},
            {'id': 'Ashley', 'label': 'Ashley', 'description': 'bright'},
            {'id': 'Hades', 'label': 'Hades', 'description': 'deep'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'default': {
        'mode': 'realtime',
        'realtime_model_id': 'gemini-live',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
      },
      'current': {
        'mode': 'realtime',
        'realtime_model_id': 'gemini-live',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
        'voice_id': 'Aoede',
        'language_code': '',
        'accent': '',
      },
    };

final List<Map<String, dynamic>> _posted = [];

ApiClient _api() {
  _posted.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(jsonEncode(_catalog()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/voice/preference') {
      _posted.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('voice list follows the selected realtime model, then cascade TTS',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Realtime/Gemini active: its selected voice shows, and the voice dropdown
    // offers the Gemini presets.
    expect(find.text('Aoede — warm'), findsOneWidget); // collapsed selection
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Charon — deep'), findsWidgets);
    await tester.tap(find.text('Charon — deep').last); // select + close
    await tester.pumpAndSettle();

    // Switch MODE to cascade → the voice dropdown now offers the TTS's voices.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Ashley — bright'), findsWidgets);
    expect(find.text('Hades — deep'), findsWidgets);
    // The Gemini-only voice is no longer offered.
    expect(find.text('Charon — deep'), findsNothing);
  });

  testWidgets('saving posts the selected stack to /voice/preference',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(_posted.first['mode'], 'realtime');
    expect(_posted.first['realtime_model_id'], 'gemini-live');
    expect(_posted.first['voice_id'], 'Aoede');
  });

  testWidgets('an unavailable realtime model is hidden, not shown disabled',
      (tester) async {
    // § founder 2026-10-28 (ISSUE 6): "if it's not selectable why bother" —
    // a model the user can't pick (no key) is filtered out of the dropdown
    // entirely, while the available one still shows.
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>).at(1)); // realtime model
    await tester.pumpAndSettle();
    expect(find.textContaining('OpenAI Realtime'), findsNothing);
    expect(find.textContaining('needs OPENAI_API_KEY'), findsNothing);
    expect(find.text('Gemini Live (native audio)'), findsWidgets);
  });

  testWidgets('the free-text accent is typed and posted to /voice/preference',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Gemini Live is active and accent-capable: the supportive note shows.
    expect(find.textContaining('from the first word'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'a southern American accent',
    );
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(_posted.first['accent'], 'a southern American accent');
  });

  testWidgets('a fixed-voice cascade TTS shows the switch-models accent note',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Switch to cascade (inworld TTS = fixed voices, no accent).
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('one fixed accent'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-accent-field')), findsOneWidget);
  });

  testWidgets('a changed accent nudges the live call (§13.9 hot-swap)',
      (tester) async {
    final voice = _FakeVoice();
    VoiceSessionController.active = voice;
    addTearDown(() => VoiceSessionController.active = null);

    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'an Irish accent',
    );
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(voice.notifyCalls, 1);
    expect(voice.lastAccent, 'an Irish accent');
    // The saved LANGUAGE label rides along (the server stores labels).
    expect(voice.lastLanguage, 'Default (English)');
  });

  testWidgets('an unchanged accent never nudges the live call',
      (tester) async {
    final voice = _FakeVoice();
    VoiceSessionController.active = voice;
    addTearDown(() => VoiceSessionController.active = null);

    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Save without touching accent or language: posted, but the live call
    // is left alone (no pointless session rebuild).
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(voice.notifyCalls, 0);
  });
}

/// A live call stand-in: records accent hot-swap nudges instead of reaching a
/// room (the real controller → transport path is covered in
/// `voice_session_controller_test.dart`).
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  int notifyCalls = 0;
  String? lastAccent;
  String? lastLanguage;

  @override
  Future<bool> notifyVoiceAccentChanged({
    required String accent,
    required String language,
  }) async {
    notifyCalls++;
    lastAccent = accent;
    lastLanguage = language;
    return true;
  }
}
