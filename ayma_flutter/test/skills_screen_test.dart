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
  Map<String, dynamic>? eligibility,
  List<Map<String, dynamic>> history = const [],
  Map<String, dynamic>? mine,
  Map<String, dynamic>? usage,
  void Function(Map<String, dynamic> body)? onAppearanceRun,
}) {
  final mockHttp = MockClient((request) async {
    const jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
    if (request.url.path == '/appearance/report') {
      onAppearanceRun?.call(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
          jsonEncode(
              {'report_id': 'rid', 'report': null, 'usage_capped': false}),
          200,
          headers: jsonUtf8);
    }
    if (request.url.path == '/appearance/coverage') {
      return http.Response(
          jsonEncode(coverage ??
              {'has_face_photo': true, 'has_body_photo': false}),
          200,
          headers: jsonUtf8);
    }
    if (request.url.path == '/appearance/eligibility') {
      return http.Response(
          jsonEncode(eligibility ??
              {
                'face': [
                  {'media_id': 'm1', 'url': 'https://example.invalid/f.png'}
                ],
                'body': const [],
                'has_face_photo': true,
                'has_body_photo': false,
              }),
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
        path: '/profile/plan',
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

  // Open the Appearance pre-run sheet and let the eligibility load resolve
  // without pumpAndSettle (the thumbnail's CachedNetworkImage would keep it
  // from ever settling).
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Appearance'));
    await tester.pump(); // start the sheet's open animation
    await tester.pump(const Duration(milliseconds: 400)); // open + load future
    await tester.pump(); // setState after eligibility resolves
  }

  testWidgets(
      'the Appearance card opens the pre-run sheet grouped into Face and Body '
      'analysis, prompting to add the missing kind', (tester) async {
    bigView(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await openSheet(tester);

    // Two clearly-labelled groups and the run action.
    expect(find.text('Face analysis'), findsOneWidget);
    expect(find.text('Body analysis'), findsOneWidget);
    expect(find.text('Run analysis'), findsOneWidget);
    // The empty body group still asks for the missing kind.
    expect(find.text('Add a full-body photo for a body report.'),
        findsOneWidget);
    // An Add photo tile now sits in BOTH groups (§ founder ISSUE 3), labelled
    // "Add", not just the empty one.
    expect(find.text('Add'), findsNWidgets(2));
    expect(find.byIcon(Icons.add_a_photo_outlined), findsNWidgets(2));
    // The old photo-source sheet is gone.
    expect(find.text('Use the photos I already have'), findsNothing);
  });

  testWidgets(
      '"Run analysis" POSTs the appearance run with the chosen face photo, '
      'body skipped (no eligible photo), in the BACKGROUND — no blocking '
      'dialog, no chat shell, no forced navigation (§ founder 2026-10-28)',
      (tester) async {
    bigView(tester);
    Map<String, dynamic>? ran;
    final api = _api(onAppearanceRun: (b) => ran = b);
    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    await openSheet(tester);
    await tester.tap(find.text('Run analysis'));
    // Sheet dismisses and the run fires in the background — the user is NOT
    // held behind a modal and is NOT navigated to the report.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The run actually happened over HTTP with the chosen ids...
    expect(ran, isNotNull);
    expect(ran!['want_face'], true); // an eligible face photo was chosen
    expect(ran!['want_body'], false); // no eligible body photo -> not run
    expect(ran!['face_media_ids'], ['m1']);
    expect(ran!.containsKey('body_media_ids'), false);
    expect(ran!['image_paths'], isEmpty);
    // ...and nothing navigated: no chat kickoff, no chat shell, no report push
    // (the background run surfaces via the report card refresh + a toast).
    expect(ChatInbox.instance.pending.value, isNull);
    expect(find.text('SHELL'), findsNothing);
    expect(find.text('APPEARANCE rid'), findsNothing);
    // We stayed on the Skills screen.
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets(
      'tapping Skip on a group with photos excludes that axis from the run',
      (tester) async {
    bigView(tester);
    Map<String, dynamic>? ran;
    // Both axes have an eligible photo this time.
    final api = _api(
      eligibility: {
        'face': [
          {'media_id': 'm1', 'url': 'https://example.invalid/f.png'}
        ],
        'body': [
          {'media_id': 'm2', 'url': 'https://example.invalid/b.png'}
        ],
        'has_face_photo': true,
        'has_body_photo': true,
      },
      onAppearanceRun: (b) => ran = b,
    );
    await tester.pumpWidget(_app(api: api));
    await tester.pumpAndSettle();

    await openSheet(tester);
    // Skip the body group (both groups show a Skip toggle here).
    await tester.tap(find.text('Skip').last);
    await tester.pump();
    await tester.tap(find.text('Run analysis'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(ran, isNotNull);
    expect(ran!['want_face'], true);
    expect(ran!['want_body'], false); // skipped
    expect(ran!['face_media_ids'], ['m1']);
    expect(ran!.containsKey('body_media_ids'), false);
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
