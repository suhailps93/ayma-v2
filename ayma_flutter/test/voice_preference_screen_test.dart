import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/voice_preview_player.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  final List<String> saved = [];
  final List<String> savedLang = [];

  @override
  Future<void> setVoicePreference(String presetName) async =>
      saved.add(presetName);

  @override
  Future<void> setVoiceLanguage(String code) async => savedLang.add(code);
}

class _FakePlayer implements VoicePreviewPlayer {
  final List<String> played = [];
  int stops = 0;
  int disposals = 0;

  @override
  Future<void> play(String url) async => played.add(url);

  @override
  Future<void> stop() async => stops++;

  @override
  void dispose() => disposals++;
}

/// Models slow `setUrl`: each play() waits on a completer the test releases,
/// and a call superseded by a newer play()/stop() must not start playback.
class _SlowPlayer implements VoicePreviewPlayer {
  final List<Completer<void>> loads = [];
  final List<String> started = [];
  String? current;
  int _token = 0;

  @override
  Future<void> play(String url) async {
    final token = ++_token;
    current = null;
    final c = Completer<void>();
    loads.add(c);
    await c.future;
    if (token != _token) return;
    started.add(url);
    current = url;
  }

  @override
  Future<void> stop() async {
    _token++;
    current = null;
  }

  @override
  void dispose() {}
}

class _FailingPlayer extends _FakePlayer {
  @override
  Future<void> play(String url) async => throw StateError('boom');
}

/// The preset names the screen asked `/voice/preview/{name}` for, in order.
final List<String> _previewRequests = [];

ApiClient _api() {
  _previewRequests.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/voice/presets') {
      return http.Response(
        jsonEncode({
          'presets': [
            {'name': 'Aoede', 'description': 'warm, bright'},
            {'name': 'Charon', 'description': 'deep, steady'},
          ],
          'current': '',
          'default': 'Aoede',
          'current_language': 'a soft Southern US accent',
          'language_examples': ['Malayalam mixed with English'],
        }),
        200,
      );
    }
    if (req.url.path.startsWith('/voice/preview/')) {
      final name = Uri.decodeComponent(req.url.pathSegments.last);
      _previewRequests.add(name);
      return http.Response(
        jsonEncode({'url': 'https://cdn.test/$name.wav'}),
        200,
      );
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('lists presets, preselects the effective one, saves a choice',
      (tester) async {
    final profiles = _FakeProfiles();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(),
        profileService: profiles,
        previewPlayer: _FakePlayer(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Aoede'), findsOneWidget);
    expect(find.text('Charon'), findsOneWidget);
    // effective == default == Aoede is selected
    expect(
      tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>)).groupValue,
      'Aoede',
    );

    await tester.tap(find.text('Charon'));
    await tester.pumpAndSettle();
    expect(profiles.saved, ['Charon']);
    expect(find.textContaining('Saved'), findsNothing);
  });

  testWidgets('rapid taps: only the last preset ends up playing',
      (tester) async {
    final player = _SlowPlayer();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(),
        profileService: _FakeProfiles(),
        previewPlayer: player,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hear Charon'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Hear Aoede'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Hear Charon'));
    await tester.pump(const Duration(milliseconds: 50));

    // Loads finish out of order: the newest first, then the stale ones.
    expect(player.loads, hasLength(3));
    player.loads[2].complete();
    await tester.pump();
    player.loads[0].complete();
    player.loads[1].complete();
    await tester.pump();

    expect(player.current, 'https://cdn.test/Charon.wav');
    expect(player.started, ['https://cdn.test/Charon.wav']);
    expect(find.byType(AymaOrb), findsNothing);

    // Not stuck: a further tap still plays.
    await tester.tap(find.byTooltip('Hear Aoede'));
    await tester.pump(const Duration(milliseconds: 50));
    player.loads[3].complete();
    await tester.pump();
    expect(player.current, 'https://cdn.test/Aoede.wav');
  });

  testWidgets('preview failures replace, not queue, the toast; leaving '
      'the screen clears it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VoicePreferenceScreen(
                api: _api(),
                profileService: _FakeProfiles(),
                previewPlayer: _FailingPlayer(),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hear Aoede'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Hear Charon'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("Couldn't play a preview."), findsOneWidget);

    Navigator.of(tester.element(find.byType(VoicePreferenceScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.text("Couldn't play a preview."), findsNothing);
  });

  testWidgets('tapping a preset plays its preview in that voice',
      (tester) async {
    final player = _FakePlayer();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(),
        profileService: _FakeProfiles(),
        previewPlayer: player,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Charon'));
    await tester.pumpAndSettle();

    expect(_previewRequests, contains('Charon'));
    expect(player.played, ['https://cdn.test/Charon.wav']);
  });

  testWidgets('accent/language is an editable text field prefilled with the '
      'current default, saved on submit', (tester) async {
    final profiles = _FakeProfiles();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(
        api: _api(),
        profileService: profiles,
        previewPlayer: _FakePlayer(),
      ),
    ));
    await tester.pumpAndSettle();

    // prefilled with Ayma's current default
    expect(find.widgetWithText(TextField, 'a soft Southern US accent'),
        findsOneWidget);

    await tester.enterText(
        find.byType(TextField), 'Malayalam mixed with English');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(profiles.savedLang, ['Malayalam mixed with English']);
  });
}
