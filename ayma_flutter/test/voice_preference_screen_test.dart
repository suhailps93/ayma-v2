import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
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

  @override
  Future<void> setVoicePreference(String presetName) async =>
      saved.add(presetName);
}

ApiClient _api() {
  final mock = MockClient((req) async {
    expect(req.url.path, '/voice/presets');
    return http.Response(
      jsonEncode({
        'presets': [
          {'name': 'Aoede', 'description': 'warm, bright'},
          {'name': 'Charon', 'description': 'deep, steady'},
        ],
        'current': '',
        'default': 'Aoede',
      }),
      200,
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('lists presets, preselects the effective one, saves a choice',
      (tester) async {
    final profiles = _FakeProfiles();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: VoicePreferenceScreen(api: _api(), profileService: profiles),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Aoede'), findsOneWidget);
    expect(find.text('Charon'), findsOneWidget);
    // effective == default == Aoede is selected
    expect(
      tester.widget<RadioListTile<String>>(
        find.widgetWithText(RadioListTile<String>, 'Aoede'),
      ).groupValue,
      'Aoede',
    );

    await tester.tap(find.text('Charon'));
    await tester.pumpAndSettle();
    expect(profiles.saved, ['Charon']);
    expect(find.textContaining('next voice session'), findsWidgets);
  });
}
