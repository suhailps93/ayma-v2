// R2-C1 regression: the preboarding free-text date-of-birth parser must read
// numeric date-first input as US MM/DD/YYYY (the launch audience's convention
// and the field's own placeholder example), NOT DD/MM. Typing 03/05/1993 must
// echo "5 March 1993", never "3 May 1993". Exercises the founder's exact path:
// type into the DOB field, read the parsed-date echo.
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProfileService extends ProfileService {
  _FakeProfileService()
      : super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'u1')));

  // Never emits — the user typing is what drives the field in this test.
  @override
  Stream<ProfileData?> watchProfile() => const Stream.empty();
}

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
          home: PreboardingFlowScreen(profileService: _FakeProfileService())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('03/05/1993 parses as 5 March 1993 (US MM/DD), not 3 May',
      (tester) async {
    await pumpScreen(tester);

    await tester.enterText(
        find.byKey(const Key('preboarding_dob')), '03/05/1993');
    await tester.pump();

    expect(find.text('→ 5 March 1993'), findsOneWidget);
    expect(find.text('→ 3 May 1993'), findsNothing);
  });

  testWidgets('all-numeric 03051993 also reads month-first (5 March 1993)',
      (tester) async {
    await pumpScreen(tester);

    await tester.enterText(
        find.byKey(const Key('preboarding_dob')), '03051993');
    await tester.pump();

    expect(find.text('→ 5 March 1993'), findsOneWidget);
  });

  testWidgets('falls back to day-first when month-first is impossible',
      (tester) async {
    await pumpScreen(tester);

    // 13 can only be a day, so this is 13 May 1990, not month 13.
    await tester.enterText(
        find.byKey(const Key('preboarding_dob')), '13/05/1990');
    await tester.pump();

    expect(find.text('→ 13 May 1990'), findsOneWidget);
  });
}
