import 'dart:convert';

import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

/// An ApiClient with canned responses for the Appearance coverage + history
/// endpoints the Skills screen calls; everything else returns `{}`.
ApiClient _api({
  Map<String, dynamic>? coverage,
  List<Map<String, dynamic>> history = const [],
}) {
  final mockHttp = MockClient((request) async {
    const jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
    if (request.url.path == '/appearance/coverage') {
      return http.Response(
          jsonEncode(coverage ??
              {'has_face_photo': true, 'has_body_photo': false}),
          200,
          headers: jsonUtf8);
    }
    if (request.url.path == '/appearance/history') {
      return http.Response(jsonEncode({'reports': history}), 200,
          headers: jsonUtf8);
    }
    return http.Response('{}', 200, headers: jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _app({String location = '/skills', ApiClient? api}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/skills',
        builder: (_, __) => SkillsScreen(
          profileService: _FakeProfileService(_profile()),
          api: api ?? _api(),
        ),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
      GoRoute(
        path: '/appearance/:id',
        builder: (_, state) =>
            Scaffold(body: Text('APPEARANCE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/physical-attributes/:id',
        builder: (_, state) =>
            Scaffold(body: Text('PHYSICAL ${state.pathParameters['id']}')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUp(() => ChatInbox.instance.take());
  tearDown(() => ChatInbox.instance.take());

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('renders the two skill actions with their credit costs',
      (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Search the web about me'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    // The three former photo cards are gone.
    expect(find.text('Facial beauty report'), findsNothing);
    expect(find.text('Physique report'), findsNothing);
    expect(find.text('Physical attributes'), findsNothing);
    expect(find.text('≈ 15 credits'), findsOneWidget);
    expect(find.text('≈ 9 credits'), findsOneWidget);
  });

  testWidgets('the web-search action opens a dialog prefilled with the name',
      (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search the web about me'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Samira Vale'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
  });

  testWidgets(
      'the Appearance card opens the photo-source sheet with a coverage line',
      (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(find.text('Use the photos I already have'), findsOneWidget);
    expect(find.text('Add photos'), findsOneWidget);
    // Coverage line: face ✓, full-length ✗ (with an inline add action).
    expect(find.text('Face photo'), findsOneWidget);
    expect(find.text('Full-length photo'), findsOneWidget);
    expect(find.text('Add a full-length photo'), findsOneWidget);
  });

  testWidgets(
      '"Use the photos I already have" pushes an appearance kickoff gated by '
      'coverage and navigates to the shell', (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use the photos I already have'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'appearance');
    expect(k.photoSource, 'existing');
    expect(k.wantFace, true); // has_face_photo
    expect(k.wantBody, false); // no full-length photo
    expect(k.attachmentPaths, isEmpty);
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('the Appearance card shows past runs that reopen the right screen',
      (tester) async {
    bigView(tester);
    final api = _api(history: [
      {
        'id': 'a9',
        'created_at': '2026-02-03T10:00:00',
        'has_face': true,
        'has_body': false,
        'summary': 'attributes · face',
        'legacy': false,
        'kind': 'appearance',
      },
      {
        'id': 'p1',
        'created_at': '2026-01-01T10:00:00',
        'summary': 'Physical profile — hair: black.',
        'legacy': true,
        'kind': 'physical',
      },
    ]);

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    expect(find.textContaining('attributes · face'), findsOneWidget);
    expect(find.text('LEGACY'), findsOneWidget);

    await tester.tap(find.textContaining('attributes · face'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE a9'), findsOneWidget);
  });
}
