import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

Widget _app({String location = '/skills'}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/skills',
        builder: (_, __) =>
            SkillsScreen(profileService: _FakeProfileService(_profile())),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUp(() => ChatInbox.instance.take());
  tearDown(() => ChatInbox.instance.take());

  testWidgets('renders the four skill actions with their credit costs',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Search the web about me'), findsOneWidget);
    expect(find.text('Facial beauty report'), findsOneWidget);
    expect(find.text('Physique report'), findsOneWidget);
    expect(find.text('Physical attributes'), findsOneWidget);
    expect(find.text('≈ 15 credits'), findsOneWidget);
    expect(find.text('≈ 4 credits'), findsNWidgets(2));
    expect(find.text('≈ 6 credits'), findsOneWidget);
  });

  testWidgets('the web-search action opens a dialog prefilled with the name',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search the web about me'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Samira Vale'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
  });

  testWidgets('tapping a photo skill shows the photo-source chooser',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Facial beauty report'));
    await tester.pumpAndSettle();

    expect(find.text('Use the photos I already have'), findsOneWidget);
    expect(find.text('Add a photo'), findsOneWidget);
  });

  testWidgets(
      '"Use the photos I already have" pushes a face_report kickoff and '
      'navigates to the shell', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Facial beauty report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use the photos I already have'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'face_report');
    expect(k.photoSource, 'existing');
    expect(k.attachmentPath, '');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets(
      'the Physical attributes card offers the chooser and pushes a '
      'physical_attributes kickoff over the existing photos', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Physical attributes'));
    await tester.pumpAndSettle();

    // multi-select wording for the Physical skill
    expect(find.text('Add photos'), findsOneWidget);
    await tester.tap(find.text('Use the photos I already have'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'physical_attributes');
    expect(k.photoSource, 'existing');
    expect(k.attachmentPaths, isEmpty);
    expect(find.text('SHELL'), findsOneWidget);
  });
}
