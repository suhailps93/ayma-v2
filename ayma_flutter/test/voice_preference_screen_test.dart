import 'dart:convert';

import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The Models screen (founder, 2026-11-06): ONE Brain picker (the same brain
/// drives text and voice — no "Brain (LLM)" picker inside Voice), and ONE
/// save button for the whole screen whose label depends on whether a voice
/// session is connected.
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

Map<String, dynamic> _brainCatalog() => {
      'brains': [
        {
          'id': 'gemini',
          'label': 'Gemini',
          'description': 'Google Gemini.',
          'available': true,
          'capabilities': ['text', 'json', 'vision', 'web', 'tools'],
        },
        {
          'id': 'meta',
          'label': 'Meta Muse Spark',
          'description': 'Meta Muse Spark.',
          'available': true,
          'capabilities': ['text', 'json', 'tools'],
        },
      ],
      'current': 'gemini',
      'default': 'gemini',
    };

final List<Map<String, dynamic>> _posts = [];

ApiClient _api() {
  _posts.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(jsonEncode(_cascadeCatalog()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/brain/preference' && req.method == 'GET') {
      return http.Response(jsonEncode(_brainCatalog()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/models/preference') {
      _posts.add({'path': req.url.path, 'body': jsonDecode(req.body)});
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/voice/preference' ||
        (req.url.path == '/brain/preference' && req.method == 'POST')) {
      _posts.add({'path': req.url.path, 'body': jsonDecode(req.body)});
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void _bigViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _host({bool voiceConnected = false}) => MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(),
        voiceConnected: () => voiceConnected,
      ),
    );

void main() {
  testWidgets('one brain: no voice-brain picker, one save button',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('Ayma’s models'), findsOneWidget);
    // The cascade TTS voice is shown — not a hardcoded Gemini preset.
    expect(find.text('Ashley — bright'), findsOneWidget);
    expect(find.text('Cascade (brain + STT + TTS)'), findsOneWidget);
    // No separate voice brain any more.
    expect(find.text('BRAIN (LLM)'), findsNothing);
    expect(find.text('SPEECH-TO-TEXT'), findsOneWidget);
    expect(find.text('TEXT-TO-SPEECH'), findsOneWidget);
    // ONE save button for the whole screen; the per-section saves are gone.
    expect(find.byKey(const ValueKey('models-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('brain-selector-save')), findsNothing);
    expect(find.byKey(const ValueKey('voice-engine-save')), findsNothing);
    expect(find.text('Save brain'), findsNothing);
    expect(find.text('Save voice'), findsNothing);
    // No voice session connected -> plain "Save".
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Save and reconnect'), findsNothing);
  });

  testWidgets('save button says "Save and reconnect" during a voice call',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host(voiceConnected: true));
    await tester.pumpAndSettle();

    expect(find.text('Save and reconnect'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('one save persists brain + voice stack in a single action',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // Pick the non-default brain (Meta Muse Spark) in the ONE Brain picker.
    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meta Muse Spark').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('models-save')));
    await tester.pumpAndSettle();

    // Exactly one POST, to /models/preference, carrying every section.
    expect(_posts, hasLength(1));
    expect(_posts.single['path'], '/models/preference');
    final body = _posts.single['body'] as Map<String, dynamic>;
    expect(body['brain'], 'meta');
    expect(body['mode'], 'cascade');
    expect(body['stt_id'], 'deepgram/nova-3');
    expect(body['tts_id'], 'inworld/inworld-tts-1');
    expect(body['voice_id'], 'Ashley');
    expect(body['reconnect'], isFalse);
  });

  testWidgets('save during a call posts reconnect=true', (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host(voiceConnected: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('models-save')));
    await tester.pumpAndSettle();

    expect(_posts, hasLength(1));
    final body = _posts.single['body'] as Map<String, dynamic>;
    expect(body['reconnect'], isTrue);
  });
}
