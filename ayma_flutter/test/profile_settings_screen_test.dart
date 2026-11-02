import 'dart:convert';

import 'package:ayma_flutter/screens/profile_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Overrides only the two Firestore-touching methods; the base constructor's
/// `FirebaseFirestore.instance` is lazy and never used.
class _FakeProfileService extends ProfileService {
  _FakeProfileService(this._initial)
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')));

  final ProfileData? _initial;
  Map<String, dynamic>? lastUpdate;
  int failNextSaves = 0;

  @override
  Future<ProfileData?> readProfile() async => _initial;

  @override
  Future<void> updateStructuredFields({
    String? name,
    String? firstName,
    String? lastName,
    String? phone,
    DateTime? birthdate,
    String? gender,
    List<String>? interestedIn,
    String? location,
  }) async {
    if (failNextSaves > 0) {
      failNextSaves--;
      throw StateError('refused');
    }
    lastUpdate = {
      'name': name,
      'first_name': firstName,
      'last_name': lastName,
      'phone': phone,
      'birthdate': birthdate,
      'gender': gender,
      'interested_in': interestedIn,
      'location': location,
    };
  }
}

void main() {
  testWidgets('loads existing fields, edits name/location, and saves',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeProfileService(ProfileData(
      name: 'Sam',
      firstName: 'Samuel',
      lastName: 'Vale',
      phone: '+15551234567',
      birthdate: DateTime(1996, 5, 4),
      gender: 'Non-binary',
      interestedIn: const ['Everyone'],
      location: 'Berlin',
    ));

    await tester.pumpWidget(
      MaterialApp(home: ProfileSettingsScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    // No separate "Name" field any more — first/last name are the inputs.
    expect(find.text('Name'), findsNothing);
    expect(find.text('Berlin'), findsOneWidget);
    expect(find.text('Samuel'), findsOneWidget);
    expect(find.text('Vale'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Berlin'), 'Lisbon');
    await tester.enterText(
        find.widgetWithText(TextField, 'Samuel'), 'Samira');
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // `name` (display name) is kept in sync with the first name.
    expect(svc.lastUpdate!['name'], 'Samira');
    expect(svc.lastUpdate!['location'], 'Lisbon');
    expect(svc.lastUpdate!['first_name'], 'Samira');
    expect(svc.lastUpdate!['last_name'], 'Vale');
    expect(svc.lastUpdate!['phone'], '+15551234567');
    expect(svc.lastUpdate!['gender'], 'Non-binary');
    expect(svc.lastUpdate!['interested_in'], ['Everyone']);
  });

  testWidgets('binds a stored DOB (server ISO-string birthdate) into the date '
      'field — R2-C3', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Build the read model the way a server-written doc produces it: an
    // ISO-8601 String birthdate, through fromMap — the exact field the voice
    // tool / seeded accounts store.
    final svc = _FakeProfileService(ProfileData.fromMap(<String, dynamic>{
      'name': 'Sam',
      'first_name': 'Sam',
      'last_name': 'Vale',
      'gender': 'Man',
      'interested_in': ['Women'],
      'location': 'Berlin',
      'birthdate': '1990-01-01',
    }));

    await tester.pumpWidget(
      MaterialApp(home: ProfileSettingsScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    // The stored DOB shows in the field; it must NOT read "Pick a date".
    expect(find.text('1990-01-01'), findsOneWidget);
    expect(find.text('Pick a date'), findsNothing);
  });

  testWidgets('a refused save offers Retry, which saves the same input',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeProfileService(ProfileData(
      name: 'Sam',
      firstName: 'Samuel',
      lastName: 'Vale',
      phone: '+15551234567',
      birthdate: DateTime(1996, 5, 4),
      gender: 'Non-binary',
      interestedIn: const ['Everyone'],
      location: 'Berlin',
    ))
      ..failNextSaves = 1;
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
          home: ProfileSettingsScreen(profileService: svc, apiClient: api)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Berlin'), 'Lisbon');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(svc.lastUpdate, isNull);
    expect(find.textContaining('Save failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(svc.lastUpdate!['location'], 'Lisbon');
    expect(find.text('Profile saved'), findsOneWidget);
  });

  testWidgets('with no profile doc, Save is disabled until fields are filled',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileSettingsScreen(profileService: _FakeProfileService(null)),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('shows the saved partner age range and distance, and saves '
      'edits through /profile/preferences', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sent = <Map<String, dynamic>>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/profile/preferences' && req.method == 'PUT') {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('no', 404);
      }),
    );
    final svc = _FakeProfileService(ProfileData(
      name: 'Sam',
      firstName: 'Sam',
      birthdate: DateTime(1996, 5, 4),
      gender: 'Man',
      interestedIn: const ['Women'],
      location: 'Berlin',
      partnerAgeMin: 26,
      partnerAgeMax: 38,
      distancePreference: '50',
    ));

    await tester.pumpWidget(MaterialApp(
        home: ProfileSettingsScreen(profileService: svc, apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Partner age range: 26–38'), findsOneWidget);
    final slider =
        tester.widget<RangeSlider>(find.byKey(const Key('profile_age_range')));
    expect(slider.min, 18); // the 18 floor
    expect(slider.values, const RangeValues(26, 38));

    await tester.tap(find.text('Anywhere is fine'));
    await tester.pump();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Only what changed is sent: the saved 26–38 range is left alone.
    expect(sent, [
      {'distance_pref': 'anywhere'}
    ]);
  });

  testWidgets('Ayma edits profile fields and preferences through ui_action',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    final sent = <Map<String, dynamic>>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/profile/preferences' && req.method == 'PUT') {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('no', 404);
      }),
    );
    final svc = _FakeProfileService(ProfileData(
      name: 'Sam',
      firstName: 'Sam',
      birthdate: DateTime(1996, 5, 4),
      gender: 'Man',
      interestedIn: const ['Women'],
      location: 'Berlin',
      partnerAgeMin: 26,
      partnerAgeMax: 38,
      distancePreference: '50',
    ));
    await tester.pumpWidget(MaterialApp(
        home: ProfileSettingsScreen(profileService: svc, apiClient: api)));
    await tester.pumpAndSettle();
    final cap = ScreenCapture(
      routeOf: () => '/settings/profile',
      popupOpen: () => false,
      settle: () => tester.pumpAndSettle(),
    );
    var s = cap.capture();
    final location = s.controls.firstWhere(
        (c) => c.type == 'field' && c.label.contains('Location'));
    expect(location.state, '"Berlin"');
    final typed = await cap.perform(
        control: location.id, label: location.label, op: 'set_text',
        value: 'Munich');
    expect(typed.ok, isTrue, reason: typed.reason);
    expect(find.text('Munich'), findsOneWidget);

    s = cap.capture();
    final anywhere =
        s.controls.firstWhere((c) => c.label.contains('Anywhere is fine'));
    expect((await cap.perform(
            control: anywhere.id, label: anywhere.label, op: 'tap'))
        .ok, isTrue);
    s = cap.capture();
    final save = s.controls.firstWhere((c) => c.label == 'Save');
    expect((await cap.perform(control: save.id, label: 'Save', op: 'tap')).ok,
        isTrue);
    expect(sent.single['distance_pref'], 'anywhere');
    handle.dispose();
  });
}
