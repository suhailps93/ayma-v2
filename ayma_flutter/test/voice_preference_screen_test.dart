import 'dart:convert';

import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The user-facing "Ayma's voice" screen now reads the SAME cloud catalog as
/// the developer control, so it works on every engine — here the active engine
/// is the Meta cascade, whose Inworld voices the screen must show (it was
/// Gemini-preset-only before).
Map<String, dynamic> _cascadeCatalog() => {
      'modes': ['realtime', 'cascade'],
      'source': 'livekit',
      'realtime_models': [
        {
          'id': 'gemini-live',
          'label': 'Gemini Live',
          'provider': 'gemini',
          'available': true,
          'voices': [
            {'id': 'Aoede', 'label': 'Aoede'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'brains': [
        {'id': 'meta-muse-spark', 'label': 'Meta Muse Spark', 'available': true},
      ],
      'stt': [
        {'id': 'deepgram/nova-3', 'label': 'deepgram/nova-3', 'available': true},
      ],
      'tts': [
        {
          'id': 'inworld/inworld-tts-1',
          'label': 'inworld/inworld-tts-1',
          'available': true,
          'voices': [
            {'id': 'Ashley', 'label': 'Ashley', 'description': 'bright'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
            {'code': 'ml-IN', 'label': 'Malayalam'},
          ],
        },
      ],
      'default': {
        'mode': 'cascade',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
      },
      'current': {
        'mode': 'cascade',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
        'voice_id': 'Ashley',
        'language_code': '',
      },
    };

ApiClient _api() {
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(jsonEncode(_cascadeCatalog()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/voice/preference') {
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('shows the active engine\'s voices from the catalog (cascade)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(api: _api()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Ayma’s voice'), findsOneWidget);
    // The cascade TTS voice is shown — not a hardcoded Gemini preset.
    expect(find.text('Ashley — bright'), findsOneWidget);
    // In the user-facing (non-fullStack) screen there is no MODE/brain picker.
    expect(find.text('Cascade (brain + STT + TTS)'), findsNothing);
    expect(find.byKey(const ValueKey('voice-engine-save')), findsOneWidget);
  });
}
