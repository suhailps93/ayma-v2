import 'package:ayma_flutter/screens/profile_settings_screen.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Overrides only the two Firestore-touching methods; the base constructor's
/// `FirebaseFirestore.instance` is lazy and never used.
class _FakeProfileService extends ProfileService {
  _FakeProfileService(this._initial)
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')));

  final ProfileData? _initial;
  Map<String, dynamic>? lastUpdate;

  @override
  Future<ProfileData?> readProfile() async => _initial;

  @override
  Future<void> updateStructuredFields({
    String? name,
    DateTime? birthdate,
    String? gender,
    List<String>? interestedIn,
    String? location,
  }) async {
    lastUpdate = {
      'name': name,
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
      birthdate: DateTime(1996, 5, 4),
      gender: 'Non-binary',
      interestedIn: const ['Everyone'],
      location: 'Berlin',
    ));

    await tester.pumpWidget(
      MaterialApp(home: ProfileSettingsScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Berlin'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Samira');
    await tester.enterText(
        find.widgetWithText(TextField, 'Berlin'), 'Lisbon');
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(svc.lastUpdate!['name'], 'Samira');
    expect(svc.lastUpdate!['location'], 'Lisbon');
    expect(svc.lastUpdate!['gender'], 'Non-binary');
    expect(svc.lastUpdate!['interested_in'], ['Everyone']);
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
}
