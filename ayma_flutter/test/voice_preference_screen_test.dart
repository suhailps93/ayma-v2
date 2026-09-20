import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/voice_preview_player.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
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
    expect(find.textContaining('next voice session'), findsWidgets);
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
