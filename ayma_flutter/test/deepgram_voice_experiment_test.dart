// Regression test for the DEV-ONLY Deepgram DIRECT voice toggle
// (branch fleet/deepgram-voice). Covers the founder's exact path: open the
// Developer screen's experiment widget, flip the switch ON, and confirm it
// saves a CASCADE voice stack whose STT/TTS are the Deepgram-direct legs with
// the picked Aura-2 voice (the Ayma Brain is left to the server). Flipping it
// OFF restores the default realtime Gemini Live voice.
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:ayma_flutter/screens/developer_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';

/// A fake catalog + save-recording ApiClient. The catalog carries the
/// deepgram-direct legs and a couple of real Aura-2 voices, exactly as the
/// server would serve them once the branch config is live.
class _FakeVoiceApi extends ApiClient {
  _FakeVoiceApi({required this.currentMode, required this.currentStt})
      : super(
          httpClient: MockClient((req) async => http.Response(
              '{"ok":true}', 200,
              headers: const {'content-type': 'application/json'})),
          auth: MockFirebaseAuth(signedIn: true),
        );

  final String currentMode;
  final String currentStt;
  VoiceSelection? saved;

  @override
  Future<VoiceCatalog> voiceEngines({Duration? timeout}) async {
    return VoiceCatalog.fromMap({
      'modes': ['realtime', 'cascade'],
      'source': 'fallback',
      'realtime_models': [
        {'id': 'gemini-live', 'label': 'Gemini Live', 'available': true},
      ],
      'stt': [
        {'id': 'deepgram/nova-3', 'provider': 'deepgram', 'available': true},
        {
          'id': 'deepgram-direct/nova-3',
          'provider': 'deepgram-direct',
          'available': true,
          'requires_secret': 'DEEPGRAM_API_KEY',
        },
      ],
      'tts': [
        {
          'id': 'deepgram-direct/aura-2',
          'provider': 'deepgram-direct',
          'available': true,
          'requires_secret': 'DEEPGRAM_API_KEY',
          'voices': [
            {'id': '', 'label': 'Default (Thalia)'},
            {'id': 'aura-2-thalia-en', 'label': 'Thalia', 'gender': 'feminine'},
            {'id': 'aura-2-zeus-en', 'label': 'Zeus', 'gender': 'masculine'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'current': {'mode': currentMode, 'stt_id': currentStt},
      'default': {'mode': 'realtime', 'realtime_model_id': 'gemini-live'},
    });
  }

  @override
  Future<void> saveVoicePreference(VoiceSelection sel) async {
    saved = sel;
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _FakeVoiceApi api) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [DeepgramVoiceExperiment(api: api)]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('toggle ON saves the Deepgram-direct cascade stack',
      (tester) async {
    final api = _FakeVoiceApi(currentMode: 'realtime', currentStt: '');
    await pump(tester, api);

    // The clearly-labelled toggle is visible and starts OFF.
    final toggle = find.byKey(const ValueKey('deepgram-exp-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.text('Use Deepgram voice'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final sel = api.saved;
    expect(sel, isNotNull);
    expect(sel!.mode, 'cascade');
    expect(sel.sttId, 'deepgram-direct/nova-3');
    expect(sel.ttsId, 'deepgram-direct/aura-2');
    // Brain id is NOT forced here — the server keeps the saved unified brain.
    expect(sel.brainId, '');
  });

  testWidgets('starts ON when the saved stack is already Deepgram-direct',
      (tester) async {
    final api = _FakeVoiceApi(
        currentMode: 'cascade', currentStt: 'deepgram-direct/nova-3');
    await pump(tester, api);

    final toggle = find.byKey(const ValueKey('deepgram-exp-toggle'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    // The Aura-2 voice picker shows while ON.
    expect(find.byKey(const ValueKey('deepgram-exp-voice')), findsOneWidget);
  });

  testWidgets('toggle OFF restores the default Gemini Live realtime voice',
      (tester) async {
    final api = _FakeVoiceApi(
        currentMode: 'cascade', currentStt: 'deepgram-direct/nova-3');
    await pump(tester, api);

    await tester.tap(find.byKey(const ValueKey('deepgram-exp-toggle')));
    await tester.pumpAndSettle();

    final sel = api.saved;
    expect(sel, isNotNull);
    expect(sel!.mode, 'realtime');
    expect(sel.realtimeModelId, 'gemini-live');
  });
}
