import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProfileService extends ProfileService {
  _FakeProfileService(this._data)
      : super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'u1')));

  final ProfileData? _data;

  @override
  Future<ProfileData?> readProfile() async => _data;
}

ProfileData _profile() => const ProfileData(
      name: 'Sam',
      firstName: 'Samira',
      lastName: 'Vale',
      phone: '',
      birthdate: null,
      gender: 'Woman',
      interestedIn: ['Everyone'],
      location: 'Lisbon',
    );

void main() {
  testWidgets('renders the three skill actions', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SkillsScreen(profileService: _FakeProfileService(_profile())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Search the web about me'), findsOneWidget);
    expect(find.text('Facial beauty report'), findsOneWidget);
    expect(find.text('Physique report'), findsOneWidget);
    // each card shows its typical credit cost
    expect(find.text('≈ 15 credits'), findsOneWidget);
    expect(find.text('≈ 4 credits'), findsNWidgets(2));
  });

  testWidgets('the web-search action opens a dialog prefilled with the name',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SkillsScreen(profileService: _FakeProfileService(_profile())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search the web about me'));
    await tester.pumpAndSettle();

    // The dialog is open with the full name prefilled and editable.
    expect(find.widgetWithText(TextField, 'Samira Vale'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
  });
}
