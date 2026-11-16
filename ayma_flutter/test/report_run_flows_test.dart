import 'package:ayma_flutter/screens/report_run_flows.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The web-search run flow that the Profile (You) tab's "Search the web about
/// me" row opens when there is no report yet — relocated out of the deleted
/// Skills menu page into report_run_flows.dart. (The Appearance pre-run sheet
/// is covered by appearance_prerun_sheet_test.dart.)

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

Widget _host(ProfileService profiles) {
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (ctx, __) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  runWebSearchFromProfile(ctx, profileService: profiles),
              child: const Text('GO'),
            ),
          ),
        ),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUp(() => ChatInbox.instance.take());
  tearDown(() => ChatInbox.instance.take());

  testWidgets('runWebSearchFromProfile opens a dialog prefilled with the name',
      (tester) async {
    await tester.pumpWidget(_host(_FakeProfileService(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GO'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Samira Vale'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
  });

  testWidgets('tapping Search queues a deep-dive kickoff and goes to the shell',
      (tester) async {
    await tester.pumpWidget(_host(_FakeProfileService(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GO'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();

    // Handed off to the Ayma chat shell …
    expect(find.text('SHELL'), findsOneWidget);
    // … with a deep-dive kickoff queued for it.
    final kickoff = ChatInbox.instance.take();
    expect(kickoff, isNotNull);
  });
}
