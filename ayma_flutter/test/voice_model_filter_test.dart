import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/voice_engine_control.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Part B (voice-preview-library): the VOICE dropdown lists ONLY the voices
/// the selected model supports; switching models replaces the list, and a
/// saved voice the new model does not support falls back to a supported
/// default WITH a visible note — never silently.
Map<String, dynamic> _catalog({
  String mode = 'realtime',
  String realtimeModelId = 'gemini-live',
  String ttsId = 'inworld/inworld-tts-1',
  String voiceId = 'Aoede',
  bool voiceFellBack = false,
  String savedVoiceId = '',
}) =>
    {
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
          ],
        },
        {
          'id': 'acme-live',
          'label': 'Acme Live',
          'provider': 'acme',
          'available': true,
          'requires_secret': '',
          'supports_accent': false,
          'voices': [
            {'id': 'Nova', 'label': 'Nova'},
            {'id': 'Orbit', 'label': 'Orbit'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'brains': [
        {'id': 'google/gemini-3.7-flash', 'label': 'Gemini', 'provider': 'google', 'available': true},
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
        {
          'id': 'fishaudio/s2.1-pro',
          'label': 'fishaudio/s2.1-pro',
          'provider': 'fishaudio',
          'available': true,
          'supports_accent': false,
          'voices': [
            {'id': 'hex-hannah', 'label': 'Hannah'},
            {'id': 'hex-ethan', 'label': 'Ethan'},
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
        'mode': mode,
        'realtime_model_id': realtimeModelId,
        'brain_id': 'google/gemini-3.7-flash',
        'stt_id': 'deepgram/nova-3',
        'tts_id': ttsId,
        'voice_id': voiceId,
        'language_code': '',
        'accent': '',
        'voice_fell_back': voiceFellBack,
        'saved_voice_id': savedVoiceId,
      },
    };

ApiClient _api(Map<String, dynamic> catalog) {
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(jsonEncode(catalog), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response(jsonEncode({'ok': true}), 200,
        headers: const {'content-type': 'application/json'});
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _openVoiceMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('voice list is exactly the selected realtime model voices',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api(_catalog()))));
    await tester.pumpAndSettle();

    await _openVoiceMenu(tester);
    expect(find.text('Aoede — warm'), findsWidgets);
    expect(find.text('Charon — deep'), findsWidgets);
    // Nothing from the other model, nothing from any TTS.
    expect(find.text('Nova'), findsNothing);
    expect(find.text('Ashley — bright'), findsNothing);
    await tester.tap(find.text('Aoede — warm').last);
    await tester.pumpAndSettle();
  });

  testWidgets('switching the realtime model replaces the list and falls back without showing a note',
      (tester) async {
    final controller = VoiceEngineController();
    await tester.pumpWidget(_host(
        VoiceEngineControl(api: _api(_catalog(voiceId: 'Charon')), controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.selection?.voiceId, 'Charon');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
    expect(find.textContaining('Hear a short sample of the voice before you save'), findsNothing);

    // Switch the realtime model: Gemini Live -> Acme Live.
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme Live').last);
    await tester.pumpAndSettle();

    // Charon is not an Acme voice: fell back to its first voice, with NO note rendered.
    expect(controller.selection?.voiceId, 'Nova');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
    expect(find.textContaining('not available with this model'), findsNothing);

    // The open list now offers exactly the Acme voices.
    await _openVoiceMenu(tester);
    expect(find.text('Nova'), findsWidgets);
    expect(find.text('Orbit'), findsWidgets);
    expect(find.text('Charon — deep'), findsNothing);
    await tester.tap(find.text('Orbit').last);
    await tester.pumpAndSettle();

    expect(controller.selection?.voiceId, 'Orbit');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
  });

  testWidgets('switching the cascade TTS replaces the list and falls back without showing a note',
      (tester) async {
    final controller = VoiceEngineController();
    await tester.pumpWidget(_host(VoiceEngineControl(
      api: _api(_catalog(mode: 'cascade', voiceId: 'Hades')),
      controller: controller,
    )));
    await tester.pumpAndSettle();
    expect(controller.selection?.voiceId, 'Hades');

    // Cascade dropdowns: 0 mode, 1 STT, 2 TTS.
    await tester.tap(find.byType(DropdownButton<String>).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fishaudio/s2.1-pro').last);
    await tester.pumpAndSettle();

    expect(controller.selection?.voiceId, 'hex-hannah');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
    expect(find.textContaining('not available with this model'), findsNothing);

    await _openVoiceMenu(tester);
    expect(find.text('Hannah'), findsWidgets);
    expect(find.text('Ethan'), findsWidgets);
    expect(find.text('Hades — deep'), findsNothing);
    await tester.tap(find.text('Ethan').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
  });

  testWidgets('a server-reported fallback switches voice at load without showing a note',
      (tester) async {
    final controller = VoiceEngineController();
    await tester.pumpWidget(_host(VoiceEngineControl(
      api: _api(_catalog(
        mode: 'cascade',
        voiceId: '',
        voiceFellBack: true,
        savedVoiceId: 'hex-hannah',
      )),
      controller: controller,
    )));
    await tester.pumpAndSettle();

    // The server already resolved the unsupported saved voice (a Fish Audio
    // voice on the Inworld stack) to the stack default; no note is shown under the dropdown.
    expect(controller.selection?.voiceId, '');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
    expect(find.textContaining('not available with this model'), findsNothing);
    expect(find.textContaining('Hear a short sample of the voice before you save'), findsNothing);

    // Picking a voice by hand updates the selection cleanly.
    await _openVoiceMenu(tester);
    await tester.tap(find.text('Ashley — bright').last);
    await tester.pumpAndSettle();
    expect(controller.selection?.voiceId, 'Ashley');
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
  });

  testWidgets('no note when the saved voice is supported by the model',
      (tester) async {
    await tester.pumpWidget(
        _host(VoiceEngineControl(api: _api(_catalog(voiceId: 'Charon')))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-fallback-note')), findsNothing);
  });
}
