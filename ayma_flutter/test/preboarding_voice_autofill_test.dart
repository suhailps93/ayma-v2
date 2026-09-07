import 'dart:async';

import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProfileService extends ProfileService {
  _FakeProfileService()
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')));

  final _ctrl = StreamController<ProfileData?>.broadcast();

  void emit(ProfileData d) => _ctrl.add(d);

  @override
  Stream<ProfileData?> watchProfile() => _ctrl.stream;
}

void main() {
  testWidgets('voice set_profile_field writes autofill the on-screen controls',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeProfileService();
    await tester.pumpWidget(
      MaterialApp(home: PreboardingFlowScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    // starts on the name step, empty
    expect(find.text('Alex'), findsNothing);

    svc.emit(const ProfileData(
      name: 'Alex',
      firstName: 'Alex',
      lastName: 'Kim',
      birthdate: null,
      gender: 'Woman',
      interestedIn: ['Everyone'],
      location: 'Lisbon, Portugal',
    ));
    await tester.pumpAndSettle();

    // the name fields autofilled (and stay editable — they're TextFields)
    expect(find.widgetWithText(TextField, 'Alex'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Kim'), findsOneWidget);
  });

  testWidgets('a value the user already typed is not overwritten',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _FakeProfileService();
    await tester.pumpWidget(
      MaterialApp(home: PreboardingFlowScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'First name'), 'My Own Name');
    await tester.pump();

    svc.emit(const ProfileData(
      name: 'Heard Wrong',
      firstName: 'Heard Wrong',
      birthdate: null,
      gender: '',
      interestedIn: [],
      location: '',
    ));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'My Own Name'), findsOneWidget);
    expect(find.text('Heard Wrong'), findsNothing);
  });
}
