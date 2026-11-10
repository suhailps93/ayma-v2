import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
import 'package:ayma_flutter/widgets/voice_engine_control.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
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
            {'code': 'es-ES', 'label': 'Spanish'},
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

    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
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

  testWidgets('live-reloads the stack when Ayma saves a mode change',
      (tester) async {
    // Founder bug 2026-11-02: the open models screen kept showing the old stack
    // after Ayma changed+saved it. A watched-field change re-fetches the
    // catalog's recomputed `current` so the dropdowns refresh in place.
    var mode = 'realtime';
    var gets = 0;
    final mock = MockClient((req) async {
      if (req.url.path == '/voice/engines') {
        gets++;
        final cat = _catalog();
        (cat['current'] as Map)['mode'] = mode;
        return http.Response(jsonEncode(cat), 200,
            headers: const {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    });
    final api = ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
    final fs = FakeFirebaseFirestore();
    final doc =
        fs.collection('users').doc('u1').collection('profile').doc('main');
    await doc.set({'ayma_voice_mode': 'realtime'});

    await tester.pumpWidget(
        _host(VoiceEngineControl(api: api, firestore: fs, uid: 'u1')));
    await tester.pumpAndSettle();
    expect(gets, 1);
    expect(find.text('BRAIN (LLM)'), findsNothing); // realtime: no cascade controls

    // Ayma switches to cascade and saves it to the model-settings doc.
    mode = 'cascade';
    await doc.set({'ayma_voice_mode': 'cascade'}, SetOptions(merge: true));
    await tester.pump(const Duration(milliseconds: 300)); // debounce window
    await tester.pumpAndSettle();
    expect(gets, greaterThanOrEqualTo(2)); // re-fetched on the change
    expect(find.text('SPEECH-TO-TEXT'), findsOneWidget); // cascade controls now (no brain picker: the one Brain is above) shown
  });

  testWidgets(
      'a slow/cold backend on the INITIAL load: stays on the spinner and '
      'recovers — never the hard "Could not load voices" error',
      (tester) async {
    // Founder bug (2026-11-03): switching the brain re-fetched /voice/engines
    // against the cold staging backend and 408'd into a hard error. The same
    // pattern on the initial open must instead ride the cold start. The first
    // logical load fails transiently; the retry succeeds.
    final api = _ColdVoiceApi(failCall: (n) => n == 1);

    await tester.pumpWidget(_host(VoiceEngineControl(api: api)));
    // First load failed + retry scheduled: loading spinner, NO hard error.
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-engine-error')), findsNothing);
    expect(find.byType(AymaWingLoader), findsOneWidget);

    // Ride out the backoff into the warm, successful load.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-engine-error')), findsNothing);
    expect(find.text('Aoede — warm'), findsOneWidget); // catalog rendered
    expect(api.calls, 2);
  });

  testWidgets(
      'a slow/cold backend on the LIVE RE-FETCH (brain switch): no hard error, '
      'recovers in place', (tester) async {
    // Open (call 1) succeeds; the re-fetch's first logical call (call 2)
    // cold-starts, its retry (call 3) succeeds with the new stack.
    final api = _ColdVoiceApi(failCall: (n) => n == 2);
    final fs = FakeFirebaseFirestore();
    final doc =
        fs.collection('users').doc('u1').collection('profile').doc('main');
    await doc.set({'ayma_voice_mode': 'realtime'});

    await tester.pumpWidget(
        _host(VoiceEngineControl(api: api, firestore: fs, uid: 'u1')));
    await tester.pumpAndSettle();
    expect(api.calls, 1);
    expect(find.text('BRAIN (LLM)'), findsNothing); // realtime, no cascade

    // Ayma switches to cascade → the watched doc changes → re-fetch, which
    // cold-starts. The control must never flash the hard error, and recovers.
    api.mode = 'cascade';
    await doc.set({'ayma_voice_mode': 'cascade'}, SetOptions(merge: true));
    await tester.pump(const Duration(milliseconds: 300)); // debounce → re-fetch
    // The re-fetch's first call cold-starts (fails); the current dropdowns stay
    // up (no spinner) and the hard error must NOT flash.
    expect(find.byKey(const ValueKey('voice-engine-error')), findsNothing);
    // Advance past the 1s backoff explicitly: with no spinner animating there
    // is no scheduled frame for pumpAndSettle to ride, so step the clock.
    await tester.pump(const Duration(seconds: 1)); // backoff elapses → retry
    await tester.pump(); // apply the successful re-fetch's setState
    expect(find.byKey(const ValueKey('voice-engine-error')), findsNothing);
    expect(find.text('SPEECH-TO-TEXT'), findsOneWidget); // cascade controls now (no brain picker: the one Brain is above)
    expect(api.calls, 3);
  });

  testWidgets(
      'a genuinely-unreachable backend ends on the error + Retry after the '
      'budget, and Retry restarts the load', (tester) async {
    // Every auto-retry fails while `down`; the founder's Retry tap (with the
    // backend now reachable) restarts the sequence and succeeds.
    final api = _ColdVoiceApi(failCall: (_) => true);

    await tester.pumpWidget(_host(VoiceEngineControl(api: api)));
    await tester.pumpAndSettle(); // exhaust the cold-start budget
    expect(find.byKey(const ValueKey('voice-engine-error')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    api.down = false; // backend reachable again
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    // Retry restarted the sequence cleanly and this time it succeeded.
    expect(find.byKey(const ValueKey('voice-engine-error')), findsNothing);
    expect(find.text('Aoede — warm'), findsOneWidget);
  });

  testWidgets('the free-text accent is typed and posted to /voice/preference',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Gemini Live is active and accent-capable: the accent field shows,
    // and its explanation sits behind the accent eye, not under the field.
    expect(find.byKey(const ValueKey('picker-info-accent')), findsOneWidget);
    expect(find.textContaining('from the first word'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'a southern American accent',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(_posted.first['accent'], 'a southern American accent');
  });

  // --- Accent card gated on accent-capability (fix/accent-card-gate-capable) ---

  testWidgets(
      '(i) accent card is VISIBLE for an accent-capable model (Gemini Live)',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Default current selection is realtime Gemini Live (supports_accent=true).
    expect(find.byKey(const ValueKey('voice-accent-field')), findsOneWidget);
    expect(find.text('ACCENT'), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-info-accent')), findsOneWidget);
    expect(find.textContaining('from the first word'), findsNothing);
  });

  testWidgets(
      '(ii) accent card is HIDDEN (no orphan note) for a fixed-accent model',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Switch to cascade → inworld TTS (supports_accent=false), mirroring the
    // repro's fishaudio/s2.1-pro fixed-accent TTS.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();

    // The card AND its helper note are both gone — no orphan note left behind.
    expect(find.byKey(const ValueKey('voice-accent-field')), findsNothing);
    expect(find.text('ACCENT'), findsNothing);
    expect(find.textContaining('one fixed accent'), findsNothing);
    expect(find.textContaining('from the first word'), findsNothing);
  });

  testWidgets('(iii) accent value is PRESERVED across a hide/show model switch',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Type an accent on the accent-capable Gemini Live.
    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'a British accent',
    );
    await tester.pumpAndSettle();

    // Switch to cascade (non-capable) — the card disappears.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-accent-field')), findsNothing);

    // Switch back to realtime — the card returns with the prior value intact.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Realtime (native audio)').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('voice-accent-field')), findsOneWidget);
    expect(find.text('a British accent'), findsOneWidget);
  });

  testWidgets(
      "(iv) saving on a non-capable model keeps the accent (hide-don't-delete) "
      'and fires NO accent-change notification',
      (tester) async {
    final voice = _FakeVoice();
    VoiceSessionController.active = voice;
    addTearDown(() => VoiceSessionController.active = null);

    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Type an accent while on the accent-capable Gemini Live (don't save yet).
    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'a British accent',
    );
    await tester.pumpAndSettle();

    // Switch to cascade (inworld TTS, non-capable) — the card hides.
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-accent-field')), findsNothing);

    // Save while on the non-capable model.
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    // Persisted (hide-don't-delete), but the live call is NOT nudged with an
    // accent the model can't honour.
    expect(_posted, hasLength(1));
    expect(_posted.first['accent'], 'a British accent');
    expect(voice.notifyCalls, 0);
  });

  testWidgets(
      '(v) on a non-capable model a LANGUAGE-only change hot-swaps, an '
      'ACCENT-only change does not',
      (tester) async {
    final voice = _FakeVoice();
    VoiceSessionController.active = voice;
    addTearDown(() => VoiceSessionController.active = null);

    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Type an accent on the capable Gemini Live (don't save), then switch to
    // the non-capable cascade TTS — the accent card hides, value preserved.
    await tester.enterText(
      find.byKey(const ValueKey('voice-accent-field')),
      'a British accent',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).first); // mode
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cascade (brain + STT + TTS)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-accent-field')), findsNothing);

    // ACCENT-only save on the non-capable model: persisted, but NOT nudged.
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();
    expect(voice.notifyCalls, 0);

    // Let the save toast auto-dismiss (3s) so its overlay stops covering the
    // dropdown below it.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // Change ONLY the language (the LANGUAGE dropdown is always shown — with
    // the accent card hidden it is the last dropdown) and save: a language
    // change DOES hot-swap live even on a fixed-accent model.
    await tester.tap(find.byType(DropdownButton<String>).last); // language
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spanish').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(voice.notifyCalls, 1);
    expect(voice.lastLanguage, 'Spanish');
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
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
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
    await tester.ensureVisible(find.byKey(const ValueKey('voice-engine-save')));
    await tester.tap(find.byKey(const ValueKey('voice-engine-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(voice.notifyCalls, 0);
  });

  // --- Jobs pass cluster 18 (fleet/jobs-models-reaudit) ---

  testWidgets('V13: voice dropdown border is the boundary token', (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    final ac = tester.element(find.byType(VoiceEngineControl)).ac;
    final container = tester.widget<Container>(find
        .ancestor(
            of: find.byKey(const ValueKey('voice-dropdown')),
            matching: find.byType(Container))
        .first);
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.top.color, ac.boundary);
  });

  testWidgets('V14: accent field border and enabledBorder are the boundary token',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    final ac = tester.element(find.byType(VoiceEngineControl)).ac;
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('voice-accent-field')));
    final deco = field.decoration!;
    expect((deco.border as OutlineInputBorder).borderSide.color, ac.boundary);
    expect((deco.enabledBorder as OutlineInputBorder).borderSide.color, ac.boundary);
  });

  testWidgets('V6/V7: picker info button is 48x48 and the MODE label tracks at 2',
      (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    final iconButton = tester.widget<IconButton>(find
        .descendant(
            of: find.byType(VoiceEngineControl), matching: find.byType(IconButton))
        .first);
    expect(iconButton.constraints,
        const BoxConstraints(minWidth: 48, minHeight: 48));

    final label = tester.widget<Text>(find.text('MODE'));
    expect(label.style?.letterSpacing, 2);
  });

  testWidgets('V8: the MODE-to-next-group gap flipped 16 -> 12', (tester) async {
    await tester.pumpWidget(_host(VoiceEngineControl(api: _api())));
    await tester.pumpAndSettle();

    // Before the fix two SizedBox(height: 16) existed: the MODE-to-next gap
    // (defect 8) and the standalone save gap (audited clean). After defect 8
    // the save gap is the only 16 box; the MODE gap joins the 12 family.
    final sixteens = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((b) => b.height == 16);
    expect(sixteens, hasLength(1));
  });

  testWidgets('V2/V5: load error uses errorText and Retry shares the left edge',
      (tester) async {
    final api = _ColdVoiceApi(failCall: (_) => true);
    await tester.pumpWidget(_host(VoiceEngineControl(api: api)));
    await tester.pumpAndSettle();

    final ac = tester.element(find.byType(VoiceEngineControl)).ac;
    final errorText =
        tester.widget<Text>(find.textContaining('Could not load voices'));
    expect(errorText.style?.color, ac.errorText);

    final errorLeft =
        tester.getTopLeft(find.textContaining('Could not load voices')).dx;
    final retryLeft = tester.getTopLeft(find.text('Retry')).dx;
    expect(retryLeft, moreOrLessEquals(errorLeft, epsilon: 0.5));
  });
}

/// An [ApiClient] that controls `/voice/engines` at the LOGICAL call level, so
/// a test drives cold-start failures deterministically (the HTTP layer's own
/// 5xx inner-retry would otherwise double-count a MockClient's calls). While
/// [down], a logical call whose number matches [failCall] throws a transient
/// 503 (cold start); otherwise it returns the catalog with the current [mode].
class _ColdVoiceApi extends ApiClient {
  _ColdVoiceApi({required this.failCall})
      : super(
          httpClient: MockClient((req) async => http.Response(
              jsonEncode({'ok': true}), 200,
              headers: const {'content-type': 'application/json'})),
          auth: MockFirebaseAuth(signedIn: true),
        );

  final bool Function(int call) failCall;
  bool down = true;
  String mode = 'realtime';
  int calls = 0;

  @override
  Future<VoiceCatalog> voiceEngines({Duration? timeout}) async {
    calls++;
    if (down && failCall(calls)) {
      throw ApiException('Request timed out — please try again.',
          statusCode: 503);
    }
    final cat = _catalog();
    (cat['current'] as Map)['mode'] = mode;
    return VoiceCatalog.fromMap(cat);
  }
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
