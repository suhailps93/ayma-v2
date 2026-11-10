// R2-C1 regression: the preboarding free-text date-of-birth parser must read
// numeric date-first input as US MM/DD/YYYY (the launch audience's convention
// and the field's own placeholder example), NOT DD/MM. Typing 03/05/1993 must
// echo "5 March 1993", never "3 May 1993". Exercises the founder's exact path:
// type into the DOB field, read the parsed-date echo.
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/services/age_gate.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
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

  // Jobs-pass cluster 19 (fleet/jobs-auth-reaudit): spacing / colour /
  // alignment only. Shared left edge is the ListView padding (20) at 1200 wide.
  group('jobs-pass geometry (cluster 19)', () {
    const left = 20.0;

    testWidgets('D7/D13: calendar icon starts at x=20 and measures 18',
        (tester) async {
      await pumpScreen(tester);

      final icon = find.byIcon(Icons.calendar_today_outlined);
      expect(tester.getTopLeft(icon).dx, closeTo(left, 0.5));
      expect(tester.widget<Icon>(icon).size, 18);
    });

    testWidgets('D6: under-18 feedback renders in the errorText token',
        (tester) async {
      await pumpScreen(tester);
      await tester.enterText(
          find.byKey(const Key('preboarding_dob')), '03/05/2015');
      await tester.pump();

      // The 24pt serif title shares this string; the feedback is the 13pt one.
      final feedback = find.byWidgetPredicate((w) =>
          w is Text &&
          w.data == AgeGate.mustBeAdultMessage &&
          w.style?.fontSize == 13);
      expect(feedback, findsOneWidget);
      final ac = tester.element(feedback).ac;
      expect(tester.widget<Text>(feedback).style?.color, ac.errorText);
    });

    testWidgets('D9: the calendar button sits 8 below the parsed feedback',
        (tester) async {
      await pumpScreen(tester);
      await tester.enterText(
          find.byKey(const Key('preboarding_dob')), '03/05/1990');
      await tester.pump();

      final feedbackBottom =
          tester.getBottomLeft(find.text('→ 5 March 1990')).dy;
      final buttonTop =
          tester.getTopLeft(find.byIcon(Icons.calendar_today_outlined)).dy;
      // The 8 gap lives in the inserted SizedBox; the TextButton.icon adds its
      // own 8 top inset above the icon, so assert the gap is at least 8.
      expect(buttonTop - feedbackBottom, greaterThanOrEqualTo(8.0));
    });

    testWidgets(
        'D8/D10/D11/D12/D13: form geometry after the age gate', (tester) async {
      await pumpScreen(tester);
      await tester.enterText(
          find.byKey(const Key('preboarding_dob')), '03/05/1990');
      await tester.pump();
      await tester.tap(find.byKey(const Key('preboarding_age_continue')));
      await tester.pumpAndSettle();

      // D8: the location button carries zero leading inset (defect 8 strips
      // the M3 TextButton.icon padding) AND is now wrapped in
      // Align(centerLeft), so its icon reaches the shared x=20 left edge like
      // the calendar button — the padding alone was not enough. D13: 18.
      final locIcon = find.byIcon(Icons.my_location);
      final locBtn = tester.widget<TextButton>(
          find.ancestor(of: locIcon, matching: find.byType(TextButton)));
      expect(locBtn.style?.padding?.resolve({}), EdgeInsets.zero);
      expect(tester.getTopLeft(locIcon).dx, closeTo(left, 0.5));
      expect(tester.widget<Icon>(locIcon).size, 18);

      // D13: selfie + photo leading icons unify at 18.
      expect(tester.widget<Icon>(find.byIcon(Icons.camera_alt_outlined)).size,
          18);
      expect(
          tester.widget<Icon>(find.byIcon(Icons.photo_library_outlined)).size,
          18);

      // D10/D11: both chip Wraps carry runSpacing 8.
      final genderWrap = tester.widget<Wrap>(find.ancestor(
          of: find.byType(ChoiceChip).first, matching: find.byType(Wrap)));
      expect(genderWrap.runSpacing, 8);
      final interestWrap = tester.widget<Wrap>(find.ancestor(
          of: find.byType(FilterChip).first, matching: find.byType(Wrap)));
      expect(interestWrap.runSpacing, 8);

      // D12: the fixed Save bar pads horizontal 20 (was all-16), so the Save
      // button lands on the form's 20 left edge once the theme stretches it
      // full-width in production.
      expect(
          find.ancestor(
              of: find.widgetWithText(FilledButton, 'Save'),
              matching: find.byWidgetPredicate((w) =>
                  w is Padding &&
                  w.padding ==
                      const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16))),
          findsOneWidget);
    });
  });
}
