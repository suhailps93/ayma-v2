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
  Map<String, dynamic>? mine,
  Map<String, dynamic>? usage,
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
    if (request.url.path == '/deep-dive/mine') {
      return http.Response(jsonEncode(mine ?? {'exists': false}), 200,
          headers: jsonUtf8);
    }
    if (request.url.path == '/usage') {
      return http.Response(
          jsonEncode(usage ??
              {
                'credits': {'grant': 100, 'added': 0, 'used': 12, 'remaining': 88},
              }),
          200,
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
      GoRoute(
        path: '/deep-dive/:id',
        builder: (_, state) =>
            Scaffold(body: Text('DEEP DIVE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/profile/usage/plans',
        builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
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

  testWidgets('renders the two skill actions without stale credit numbers',
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
    expect(find.text('Uses credits'), findsNWidgets(2));
    expect(find.textContaining('≈'), findsNothing);
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
    // Coverage line: face ✓, body ✗ (with an inline add action).
    expect(find.text('Face photo'), findsOneWidget);
    expect(find.text('Body photo'), findsOneWidget);
    expect(find.text('Add a body photo'), findsOneWidget);
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
    expect(k.wantBody, false); // no body photo
    expect(k.attachmentPaths, isEmpty);
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('a persistent credits row shows the balance and taps through to '
      'the plans screen', (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('88 credits left'), findsOneWidget);
    expect(find.text('Upgrade'), findsOneWidget);

    await tester.tap(find.text('Upgrade'));
    await tester.pumpAndSettle();

    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets(
      "the Appearance card shows a single 'View my report' link once the "
      'skill has ever run, opening the one persistent report screen',
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
    ]);

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    // No growing history list — just one link, and never the per-run
    // legacy/summary details a history row used to show.
    expect(find.text('View my report'), findsNWidgets(1));
    expect(find.textContaining('attributes · face'), findsNothing);
    expect(find.text('LEGACY'), findsNothing);

    await tester.tap(find.text('View my report'));
    await tester.pumpAndSettle();
    // Always the caller's *current* report — never a specific past run id.
    expect(find.text('APPEARANCE current'), findsOneWidget);
  });

  testWidgets(
      "the Appearance card shows nothing when the skill has never run",
      (tester) async {
    bigView(tester);
    final api = _api(history: const []);

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    expect(find.text('View my report'), findsNWidgets(0));
  });

  testWidgets(
      "the web-search card shows a single 'View my report' link for the "
      'current self-dive and opens the full report on tap', (tester) async {
    bigView(tester);
    final api = _api(mine: {
      'exists': true,
      'report_id': 'name_samira-vale',
      'summary': 'Samira is a product designer in Lisbon.',
      'confidence': 'high',
      'created_at': '2026-02-03T10:00:00',
    });

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    // A link, not a summary preview of the report's content.
    expect(find.text('View my report'), findsNWidgets(1));
    expect(
        find.text('Samira is a product designer in Lisbon.'), findsNothing);

    await tester.tap(find.text('View my report'));
    await tester.pumpAndSettle();
    expect(find.text('DEEP DIVE name_samira-vale'), findsOneWidget);
  });

  testWidgets(
      'the web-search card shows nothing when no self-dive has ever run',
      (tester) async {
    bigView(tester);
    final api = _api(mine: {'exists': false});

    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.travel_explore), findsOneWidget); // card icon
    expect(find.text('View my report'), findsNWidgets(0));
  });
}
