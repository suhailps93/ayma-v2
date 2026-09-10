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

Widget _app({String location = '/skills', ApiClient? api}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/skills',
        builder: (_, __) => SkillsScreen(
          profileService: _FakeProfileService(_profile()),
          api: api,
        ),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
      GoRoute(
        path: '/physical-attributes/:id',
        builder: (_, state) =>
            Scaffold(body: Text('REPORT ${state.pathParameters['id']}')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

/// An ApiClient whose only real response is `GET /physical-attributes/history`.
ApiClient _historyApi(List<Map<String, dynamic>> rows) {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/physical-attributes/history') {
      return http.Response(jsonEncode({'reports': rows}), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
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

  testWidgets(
      'the Physical attributes card shows past runs that reopen the report',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _historyApi([
      {
        'id': 'r9',
        'summary': 'Physical profile — hair: black (from photos); build: '
            'athletic (stated).',
        'photo_count': 4,
        'attribute_count': 6,
        'created_at': '2026-02-03T10:00:00',
      },
    ]);

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    // one-line summary, prefix trimmed
    expect(
      find.textContaining('hair: black (from photos); build: athletic (stated)'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('hair: black (from photos)'));
    await tester.pumpAndSettle();

    expect(find.text('REPORT r9'), findsOneWidget);
  });
}
