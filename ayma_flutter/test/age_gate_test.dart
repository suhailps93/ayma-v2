import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/screens/underage_screen.dart';
import 'package:ayma_flutter/services/age_gate.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final declared = <String>[];

  @override
  Future<void> declareBirthdate(String isoDate) async => declared.add(isoDate);
}

void main() {
  group('AgeGate', () {
    test('birthday boundary', () {
      final now = DateTime(2026, 6, 15);
      expect(AgeGate.isAdult(DateTime(2008, 6, 15), now: now), isTrue);
      expect(AgeGate.isAdult(DateTime(2008, 6, 16), now: now), isFalse);
      expect(AgeGate.isAdult(DateTime(2010, 1, 1), now: now), isFalse);
    });

    test('leap day birthday counts from Mar 1 in a common year', () {
      final bd = DateTime(2008, 2, 29);
      expect(AgeGate.ageOn(bd, DateTime(2026, 2, 28)), 17);
      expect(AgeGate.ageOn(bd, DateTime(2026, 3, 1)), 18);
    });

    test('latestAdultBirthdate is exactly 18 years back, leap-safe', () {
      expect(AgeGate.latestAdultBirthdate(now: DateTime(2026, 6, 15)),
          DateTime(2008, 6, 15));
      expect(AgeGate.latestAdultBirthdate(now: DateTime(2028, 2, 29)),
          DateTime(2010, 2, 28));
      final latest = AgeGate.latestAdultBirthdate(now: DateTime(2026, 6, 15));
      expect(AgeGate.isAdult(latest, now: DateTime(2026, 6, 15)), isTrue);
    });

    test('isoDate is zero-padded', () {
      expect(AgeGate.isoDate(DateTime(2001, 2, 3)), '2001-02-03');
    });
  });

  test('profile writes refuse an under-18 birthdate', () {
    final svc = ProfileService(
      auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
    );
    final now = DateTime.now();
    final minor = DateTime(now.year - 17, now.month, now.day);
    expect(() => svc.updateStructuredFields(birthdate: minor),
        throwsA(isA<UnderageBirthdateException>()));
    expect(
      () => svc.savePreboarding(
        name: 'A',
        birthdate: minor,
        gender: 'Woman',
        interestedIn: const ['Men'],
        location: 'X',
        photoStoragePath: 'p',
      ),
      throwsA(isA<UnderageBirthdateException>()),
    );
  });

  testWidgets('under-18 entry in preboarding is a hard stop, reported to server',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeApi();
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => PreboardingFlowScreen(apiClient: api),
      ),
      GoRoute(
          path: UnderageScreen.path, builder: (_, __) => const UnderageScreen()),
      GoRoute(path: TermsScreen.path, builder: (_, __) => const TermsScreen()),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    final year = DateTime.now().year - 15;
    await tester.enterText(
        find.byKey(const Key('preboarding_dob')), '01/01/$year');
    await tester.pump();
    expect(find.text(AgeGate.mustBeAdultMessage), findsWidgets);
    expect(find.byKey(const Key('preboarding_first_name')), findsNothing);

    await tester.tap(find.byKey(const Key('preboarding_age_continue')));
    await tester.pumpAndSettle();

    expect(api.declared, ['$year-01-01']);
    expect(find.byKey(const Key('underage_title')), findsOneWidget);
    expect(find.byKey(const Key('preboarding_dob')), findsNothing);
    // the only way onward is the Terms
    await tester.tap(find.byKey(const Key('underage_terms')));
    await tester.pumpAndSettle();
    expect(find.text('Terms of Service'), findsOneWidget);
  });

  testWidgets('continue with no date explains instead of advancing',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PreboardingFlowScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preboarding_age_continue')));
    await tester.pump();
    expect(find.text('Enter your date of birth to continue.'), findsOneWidget);
    expect(find.byKey(const Key('preboarding_first_name')), findsNothing);
  });

  testWidgets('hard stop screen shows the message and offers only terms/sign out',
      (tester) async {
    var signedOut = false;
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) =>
            UnderageScreen(signOut: () async => signedOut = true),
      ),
      GoRoute(path: '/signin', builder: (_, __) => const Text('signin')),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('You must be 18 or older to use Ayma.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.byKey(const Key('underage_sign_out')));
    await tester.pumpAndSettle();
    expect(signedOut, isTrue);
  });
}
