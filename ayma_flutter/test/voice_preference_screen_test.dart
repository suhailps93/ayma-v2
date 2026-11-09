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

Map<String, dynamic> _imageCatalog() => {
      'models': [
        {
          'id': 'gemini-direct',
          'label': 'Gemini (Google)',
          'description': 'Google Gemini image model.',
          'model': 'gemini-2.5-flash-image',
          'available': true,
        },
      ],
      'current': 'gemini-direct',
      'default': 'gemini-direct',
    };

Map<String, dynamic> _realtimeCatalog() => {
      'modes': ['realtime', 'cascade'],
      'source': 'livekit',
      'realtime_models': [
        {
          'id': 'gemini-live',
          'label': 'Gemini Live',
          'provider': 'gemini',
          'available': true,
          'supports_accent': true,
          'voices': [
            {'id': 'Aoede', 'label': 'Aoede'},
            {'id': 'Charon', 'label': 'Charon'},
          ],
          'languages': [
            {'code': '', 'label': 'Default (English)'},
          ],
        },
      ],
      'brains': [
        {'id': 'gemini', 'label': 'Gemini', 'available': true},
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
          ],
        },
        {
          'id': 'fishaudio/s2.1-pro',
          'label': 'fishaudio/s2.1-pro',
          'available': true,
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
        'brain_id': 'gemini',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
      },
      'current': {
        'mode': 'realtime',
        'realtime_model_id': 'gemini-live',
        'brain_id': 'gemini',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
        'voice_id': 'Aoede',
        'language_code': '',
      },
    };

final List<Map<String, dynamic>> _posts = [];

ApiClient _api({Map<String, dynamic> Function()? voiceCatalog}) {
  _posts.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/engines') {
      return http.Response(jsonEncode((voiceCatalog ?? _cascadeCatalog)()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/brain/preference' && req.method == 'GET') {
      return http.Response(jsonEncode(_brainCatalog()), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/image-model/preference' && req.method == 'GET') {
      return http.Response(jsonEncode(_imageCatalog()), 200,
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

Widget _host({
  bool voiceConnected = false,
  Map<String, dynamic> Function()? voiceCatalog,
}) =>
    MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(voiceCatalog: voiceCatalog),
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
    expect(body['image_model'], 'gemini-direct'); // the image picker's value
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

  testWidgets('clean list: no sections or paragraphs, an info icon per picker',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // No Brain/Voice section headers and no always-visible paragraphs:
    // not the section blurbs, not the intro, not the catalog footer.
    expect(find.text('Brain'), findsNothing);
    expect(find.text('Voice'), findsNothing);
    expect(find.textContaining('The one LLM behind Ayma'), findsNothing);
    expect(find.textContaining('How Ayma listens and speaks'), findsNothing);
    expect(find.textContaining('Switch Ayma\u2019s model stack'), findsNothing);
    expect(find.textContaining('Options are pulled live'), findsNothing);
    expect(find.textContaining('Ayma speaks with this accent'), findsNothing);

    // The small field labels stay; the per-brain description line under the
    // Brain dropdown is removed (Nov 8 founder order).
    for (final label in [
      'BRAIN',
      'IMAGE MODEL',
      'MODE',
      'SPEECH-TO-TEXT',
      'TEXT-TO-SPEECH',
      'VOICE',
      'LANGUAGE',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Google Gemini.'), findsNothing);

    // One info icon per picker in cascade mode; the realtime info icon stays home.
    for (final key in [
      'picker-info-brain',
      'picker-info-image',
      'picker-info-mode',
      'picker-info-stt',
      'picker-info-tts',
      'picker-info-voice',
      'picker-info-language',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.byKey(const ValueKey('picker-info-realtime-model')),
        findsNothing);
    expect(find.byIcon(Icons.info_outline), findsNWidgets(7));
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);

    // Tapping the Brain info icon opens its explanation in a sheet.
    await tester.tap(find.byKey(const ValueKey('picker-info-brain')));
    await tester.pumpAndSettle();
    expect(find.text('Brain'), findsOneWidget);
    expect(
      find.textContaining('The one brain behind everything Ayma does'),
      findsOneWidget,
    );

    // Dismiss the Brain sheet and tap the Voice info icon.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-info-voice')));
    await tester.pumpAndSettle();
    expect(find.text('Voice'), findsOneWidget);
    expect(
      find.textContaining('How Ayma sounds when she speaks on a call'),
      findsOneWidget,
    );

    // Dismiss, then the Image model picker renders with its info sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-model-dropdown')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-info-image')));
    await tester.pumpAndSettle();
    expect(find.text('Image model'), findsOneWidget);
    expect(
      find.textContaining('The model Ayma uses to create and edit images'),
      findsOneWidget,
    );
  });

  testWidgets('realtime mode: realtime + accent info icons, no cascade info icons',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(voiceCatalog: _realtimeCatalog),
        voiceConnected: () => false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('REALTIME MODEL'), findsOneWidget);
    expect(find.text('SPEECH-TO-TEXT'), findsNothing);
    expect(find.text('TEXT-TO-SPEECH'), findsNothing);
    expect(find.byKey(const ValueKey('picker-info-realtime-model')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('picker-info-accent')), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-info-stt')), findsNothing);
    expect(find.byKey(const ValueKey('picker-info-tts')), findsNothing);
    // The accent explanation moved behind its info icon \u2014 not a line under
    // the field any more.
    expect(find.textContaining('Ayma speaks with this accent'), findsNothing);

    // Tapping the Accent info icon opens its explanation in a sheet.
    await tester.tap(find.byKey(const ValueKey('picker-info-accent')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Type how you want her to sound'),
      findsOneWidget,
    );
  });

  testWidgets(
      'the VOICE list filters by realtimeModelId in realtime mode and ttsId in cascade mode, unaffected by brain',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host(voiceCatalog: _realtimeCatalog));
    await tester.pumpAndSettle();

    // In Realtime mode, the active voice is from Gemini Live.
    expect(find.text('Aoede'), findsOneWidget);

    // Opening the VOICE dropdown shows Gemini Live voices.
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Aoede'), findsWidgets);
    expect(find.text('Charon'), findsWidgets);
    expect(find.text('Ashley — bright'), findsNothing);
    await tester.tap(find.text('Aoede').last);
    await tester.pumpAndSettle();

    // Changing BRAIN (LLM reasoning) does NOT change or filter the realtime voice list
    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meta Muse Spark').last);
    await tester.pumpAndSettle();

    // VOICE dropdown still shows Gemini Live voices — unchanged by brain.
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Aoede'), findsWidgets);
    expect(find.text('Charon'), findsWidgets);
    expect(find.text('Ashley — bright'), findsNothing);
    await tester.tap(find.text('Aoede').last);
    await tester.pumpAndSettle();

    // Switch MODE to Cascade
    await tester.tap(find.byType(DropdownButton<String>).at(1)); // Mode dropdown
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();

    // In Cascade mode, the voice list is keyed by ttsId (inworld-tts-1 initially)
    expect(find.text('Ashley — bright'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Ashley — bright'), findsWidgets);
    expect(find.text('Aoede'), findsNothing);
    await tester.tap(find.text('Ashley — bright').last);
    await tester.pumpAndSettle();

    // Switching TTS changes the voice list
    await tester.tap(find.widgetWithText(DropdownButton<String>, 'inworld/inworld-tts-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fishaudio/s2.1-pro').last);
    await tester.pumpAndSettle();

    // Now voices are from Fish Audio (Default voice, Speaker 1)
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Default voice'), findsWidgets);
    expect(find.text('Speaker 1'), findsWidgets);
    expect(find.text('Ashley — bright'), findsNothing);
    await tester.tap(find.text('Speaker 1').last);
    await tester.pumpAndSettle();

    // Changing BRAIN again does NOT touch the cascade TTS voice list
    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Default voice'), findsWidgets);
    expect(find.text('Speaker 1'), findsWidgets);
    await tester.tap(find.text('Speaker 1').last);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'save button disables after successful save and re-enables on change',
      (tester) async {
    _bigViewport(tester);
    await tester.pumpWidget(_host(voiceCatalog: _realtimeCatalog));
    await tester.pumpAndSettle();

    // Pristine: Save button is disabled (not pink)
    var btn = tester.widget<FilledButton>(find.byKey(const ValueKey('models-save')));
    expect(btn.onPressed, isNull);

    // Pick a different brain (Meta Muse Spark)
    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meta Muse Spark').last);
    await tester.pumpAndSettle();

    // Dirty: Save button is enabled
    btn = tester.widget<FilledButton>(find.byKey(const ValueKey('models-save')));
    expect(btn.onPressed, isNotNull);

    // Revert brain back to Gemini
    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini').last);
    await tester.pumpAndSettle();

    // Pristine again: Save button is disabled
    btn = tester.widget<FilledButton>(find.byKey(const ValueKey('models-save')));
    expect(btn.onPressed, isNull);

    // Pick a different voice (Charon)
    await tester.tap(find.byKey(const ValueKey('voice-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charon').last);
    await tester.pumpAndSettle();

    // Dirty again: Save button is enabled
    btn = tester.widget<FilledButton>(find.byKey(const ValueKey('models-save')));
    expect(btn.onPressed, isNotNull);

    // Tap Save
    await tester.tap(find.byKey(const ValueKey('models-save')));
    await tester.pumpAndSettle();

    // Saved: Save button is disabled again (no longer pink)
    btn = tester.widget<FilledButton>(find.byKey(const ValueKey('models-save')));
    expect(btn.onPressed, isNull);
  });
}
