import 'dart:convert';

import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Capture url_launcher calls; returns the launched URL strings in order.
List<String> _mockLaunches(WidgetTester tester) {
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (call) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
        return true;
      }
      if (call.method == 'canLaunch') return true;
      return null;
    },
  );
  return launched;
}

ApiClient _api(Map<String, dynamic> body) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/deep-dive-report/')) {
          return http.Response(jsonEncode(body), 200);
        }
        return http.Response('no', 404);
      }),
    );

/// Like [_api], but also mocks `POST /deep-dive` for the "Search again"
/// action — [reRuns] captures each request body.
ApiClient _apiWithReRun(
  Map<String, dynamic> reportBody, {
  required List<Map<String, dynamic>> reRuns,
  Map<String, dynamic> reRunResponse = const {'queued': true},
}) =>
    ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/deep-dive-report/')) {
          return http.Response(jsonEncode(reportBody), 200);
        }
        if (req.url.path == '/deep-dive' && req.method == 'POST') {
          reRuns.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(reRunResponse), 200);
        }
        return http.Response('no', 404);
      }),
    );

/// Like [_api], but also mocks `POST /deep-dive/{id}/facts/{id}/dispute` —
/// [disputes] captures each disputed report/fact id pair, and [disputeStatus]
/// controls the response code.
ApiClient _apiWithDispute(
  Map<String, dynamic> reportBody, {
  required List<String> disputes,
  int disputeStatus = 200,
}) =>
    ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/deep-dive-report/')) {
          return http.Response(jsonEncode(reportBody), 200);
        }
        if (req.url.path.contains('/facts/') &&
            req.url.path.endsWith('/dispute') &&
            req.method == 'POST') {
          disputes.add(req.url.path);
          return http.Response(
              disputeStatus == 200 ? '{"ok":true}' : 'no', disputeStatus);
        }
        return http.Response('no', 404);
      }),
    );

/// Like [_api], but also mocks `POST /deep-dive/{id}/correct` — every request
/// is captured in [corrections], and [reply] fn decides what to send back.
ApiClient _apiWithCorrect(
  Map<String, dynamic> reportBody,
  List<Map<String, dynamic>> corrections, {
  Map<String, dynamic> Function(Map<String, dynamic> req)? reply,
}) =>
    ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/deep-dive-report/')) {
          return http.Response(jsonEncode(reportBody), 200);
        }
        if (req.url.path.endsWith('/correct') && req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          corrections.add(body);
          final resp = reply?.call(body) ??
              {'ok': true, 'reply': 'Updated.', 'action': 'revise',
               'digest': reportBody['digest']};
          return http.Response(jsonEncode(resp), 200,
              headers: const {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('no', 404);
      }),
    );

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3000);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
  });

  testWidgets('renders the summary and a verified web-photo gallery',
      (tester) async {
    final api = _api({
      'name': 'Dana Reyes',
      'is_self': false,
      'subject_image': '',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Marine biologist in Lisbon.',
        'confidence': 'high',
        'facts': [
          {'claim': 'Works at the Oceanário', 'category': 'work',
           'source_url': 'https://oceanario.pt', 'confidence': 'high'},
        ],
        'links': [],
        'web_images': [
          {'url': 'https://img.example/a.jpg',
           'source_page': 'https://news.example/dana',
           'similarity': 0.82, 'verified': true},
          {'url': 'https://img.example/b.jpg', 'source_page': '',
           'similarity': 0.3, 'verified': false},
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_x', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Marine biologist in Lisbon.'), findsOneWidget);
    expect(find.text('PHOTOS FOUND ONLINE — FACE-MATCHED'), findsOneWidget);
    // Only the verified one is shown, with its match score + an open affordance.
    expect(find.text('match 82% · open ↗'), findsOneWidget);
    expect(find.textContaining('unverified'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the AppBar "Ask Ayma" action pushes a draft_about kickoff',
      (tester) async {
    addTearDown(() => ChatInbox.instance.take());
    final api = _api({
      'name': 'Dana Reyes',
      'target_uid': 'u_dana',
      'subject_image': 'https://img.example/dana.jpg',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Marine biologist in Lisbon.',
        'facts': [],
        'links': [],
        'web_images': [],
      },
    });

    final router = GoRouter(
      initialLocation: '/report',
      routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('SHELL'))),
        GoRoute(
          path: '/report',
          builder: (_, __) =>
              DeepDiveReportScreen(reportId: 'dive1', apiClient: api),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'draft_about');
    expect(k.shareKind, 'deep_dive');
    expect(k.refId, 'dive1');
    expect(k.targetUid, 'u_dana');
    expect(k.label, 'Dana Reyes');
    expect(find.text('SHELL'), findsOneWidget); // navigated to the shell
  });

  testWidgets('image thumbnail tap opens the source page', (tester) async {
    final launched = _mockLaunches(tester);
    final api = _api({
      'name': 'Dana Reyes',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'x',
        'web_images': [
          {
            'url': 'https://img.example/a.jpg',
            'source_page': 'https://news.example/dana',
            'similarity': 0.82,
            'verified': true,
          },
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_x', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(launched, ['https://news.example/dana']);
  });

  testWidgets('Social profiles section renders confident handles + is tappable',
      (tester) async {
    final launched = _mockLaunches(tester);
    final api = _api({
      'name': 'Dana Reyes',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Marine biologist.',
        'social_handles': [
          {
            'platform': 'instagram',
            'handle': 'dana.reyes',
            'url': 'https://www.instagram.com/dana.reyes/',
            'display_name': 'Dana Reyes',
            'confidence': 'high',
            'verified_by': ['face', 'name'],
          },
          {
            'platform': 'linkedin',
            'handle': 'dana-reyes',
            'url': 'https://www.linkedin.com/in/dana-reyes/',
            'display_name': '',
            'confidence': 'medium',
            'verified_by': ['name', 'link'],
          },
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_x', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('SOCIAL PROFILES'), findsOneWidget);
    expect(find.text('@dana.reyes'), findsOneWidget);
    expect(find.text('@dana-reyes'), findsOneWidget);
    expect(find.text('verified'), findsOneWidget);
    expect(find.text('likely'), findsOneWidget);

    await tester.tap(find.text('@dana.reyes'));
    await tester.pumpAndSettle();
    expect(launched, ['https://www.instagram.com/dana.reyes/']);
  });

  testWidgets('Social profiles section hidden when there are no handles',
      (tester) async {
    final api = _api({
      'name': 'Dana Reyes',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Nothing much.',
        'social_handles': [],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_x', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('SOCIAL PROFILES'), findsNothing);
  });

  testWidgets('no gallery section when there are no web images', (tester) async {
    final api = _api({
      'name': 'Dana Reyes',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Nothing much.',
        'facts': [],
        'links': [],
        'web_images': [],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_x', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('PHOTOS'), findsNothing);
  });

  testWidgets(
      'the "Search again" action force re-runs a dive on someone else',
      (tester) async {
    final reRuns = <Map<String, dynamic>>[];
    final api = _apiWithReRun({
      'name': 'Dana Reyes',
      'target_uid': 'u_dana',
      'digest': {'name': 'Dana Reyes', 'summary': 'x'},
    }, reRuns: reRuns);

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_u_dana', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(reRuns, [
      {'target_uid': 'u_dana', 'name': 'Dana Reyes', 'context': '', 'force': true},
    ]);
    expect(find.textContaining('Searching again for Dana Reyes'), findsOneWidget);
  });

  testWidgets('"Search again" on your own report targets no one but you',
      (tester) async {
    final reRuns = <Map<String, dynamic>>[];
    final api = _apiWithReRun({
      'name': 'Suhail Pallath',
      'is_self': true,
      'digest': {'name': 'Suhail Pallath', 'summary': 'x'},
    }, reRuns: reRuns);

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(reRuns, [
      {
        'target_uid': '',
        'name': 'Suhail Pallath',
        'context': '',
        'force': true,
      },
    ]);
    expect(find.textContaining("Searching again — I'll message you"),
        findsOneWidget);
  });

  testWidgets('a capped "Search again" shows the Reload snack instead',
      (tester) async {
    final reRuns = <Map<String, dynamic>>[];
    final api = _apiWithReRun({
      'name': 'Dana Reyes',
      'target_uid': 'u_dana',
      'digest': {'name': 'Dana Reyes', 'summary': 'x'},
    }, reRuns: reRuns, reRunResponse: const {'usage_capped': true});

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_u_dana', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(reRuns, hasLength(1));
    expect(find.textContaining('out of credits'), findsOneWidget);
    expect(find.text('Reload'), findsOneWidget);
  });

  testWidgets(
      'marking a self-dive fact incorrect calls the endpoint and removes it',
      (tester) async {
    final disputes = <String>[];
    final api = _apiWithDispute({
      'name': 'Suhail Pallath',
      'is_self': true,
      'digest': {
        'name': 'Suhail Pallath',
        'summary': 'x',
        'facts': [
          {'id': 'aaa111', 'claim': 'Went to MIT', 'category': 'education',
           'confidence': 'medium'},
          {'id': 'bbb222', 'claim': 'Works at Acme', 'category': 'work',
           'confidence': 'high'},
        ],
        'links': [],
      },
    }, disputes: disputes);

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('• Went to MIT'), findsOneWidget);
    expect(find.text('• Works at Acme'), findsOneWidget);
    expect(find.byTooltip('Mark incorrect'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Mark incorrect').first);
    await tester.pumpAndSettle();

    expect(disputes, ['/deep-dive/name_suhail-pallath/facts/aaa111/dispute']);
    expect(find.text('• Went to MIT'), findsNothing);
    expect(find.text('• Works at Acme'), findsOneWidget);
    expect(find.textContaining('Noted'), findsOneWidget);
  });

  testWidgets('a failed dispute leaves the fact on screen with an error snack',
      (tester) async {
    final disputes = <String>[];
    final api = _apiWithDispute({
      'name': 'Suhail Pallath',
      'is_self': true,
      'digest': {
        'name': 'Suhail Pallath',
        'summary': 'x',
        'facts': [
          {'id': 'aaa111', 'claim': 'Went to MIT', 'category': 'education',
           'confidence': 'medium'},
        ],
        'links': [],
      },
    }, disputes: disputes, disputeStatus: 500);

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Mark incorrect'));
    await tester.pumpAndSettle();

    expect(disputes, hasLength(1));
    expect(find.text('• Went to MIT'), findsOneWidget); // still there
    expect(find.textContaining("Couldn't record"), findsOneWidget);
  });

  testWidgets('no "mark incorrect" affordance on a report about someone else',
      (tester) async {
    final api = _api({
      'name': 'Dana Reyes',
      'is_self': false,
      'target_uid': 'u_dana',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'x',
        'facts': [
          {'id': 'aaa111', 'claim': 'Works at the Oceanário',
           'category': 'work', 'confidence': 'high'},
        ],
        'links': [],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_u_dana', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('• Works at the Oceanário'), findsOneWidget);
    expect(find.byTooltip('Mark incorrect'), findsNothing);
  });

  // --- tap-a-claim conversational correction ------------------------------

  testWidgets('tapping the summary opens the correction sheet and applies '
      'the revised summary', (tester) async {
    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrect(
      {
        'name': 'Suhail Pallath',
        'is_self': true,
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'Works in tech.',
          'facts': [],
          'links': [],
        },
      },
      corrections,
      reply: (req) => {
        'ok': true, 'reply': 'Updated your summary.', 'action': 'revise',
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'Works in tech, based in Austin.',
          'facts': [],
          'links': [],
        },
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Works in tech.'));
    await tester.pumpAndSettle();

    expect(find.text('Correct with Ayma'), findsOneWidget);
    await tester.enterText(find.byType(TextField), "I'm based in Austin");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(corrections, [
      {'target': 'summary', 'feedback': "I'm based in Austin"},
    ]);
    expect(find.text('Updated your summary.'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20)); // dismiss
    await tester.pumpAndSettle();

    expect(find.text('Works in tech, based in Austin.'), findsOneWidget);
    expect(find.text('Works in tech.'), findsNothing);
  });

  testWidgets('tapping a fact opens the correction sheet targeted at that '
      'fact and applies the returned digest', (tester) async {
    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrect(
      {
        'name': 'Suhail Pallath',
        'is_self': true,
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'x',
          'facts': [
            {'id': 'aaa111', 'claim': 'Went to MIT', 'category': 'education',
             'confidence': 'medium'},
          ],
          'links': [],
        },
      },
      corrections,
      reply: (req) => {
        'ok': true, 'reply': 'Fixed it.', 'action': 'revise',
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'x',
          'facts': [
            {'id': 'aaa111', 'claim': 'Went to MIT Sloan',
             'category': 'education', 'confidence': 'medium'},
          ],
          'links': [],
        },
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('• Went to MIT'));
    await tester.pumpAndSettle();

    expect(find.text('Correct with Ayma'), findsOneWidget);
    expect(find.text('EDUCATION'), findsOneWidget); // sheet quote header

    await tester.enterText(find.byType(TextField), 'it was Sloan specifically');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(corrections, [
      {'target': 'fact:aaa111', 'feedback': 'it was Sloan specifically'},
    ]);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('• Went to MIT Sloan'), findsOneWidget);
    expect(find.text('• Went to MIT'), findsNothing);
  });

  testWidgets('a "remove" correction drops the fact from the list',
      (tester) async {
    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrect(
      {
        'name': 'Suhail Pallath',
        'is_self': true,
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'x',
          'facts': [
            {'id': 'aaa111', 'claim': 'Went to MIT', 'category': 'education'},
            {'id': 'bbb222', 'claim': 'Works at Acme', 'category': 'work'},
          ],
          'links': [],
        },
      },
      corrections,
      reply: (req) => {
        'ok': true, 'reply': "Removed — sorry about that.", 'action': 'remove',
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'x',
          'facts': [
            {'id': 'bbb222', 'claim': 'Works at Acme', 'category': 'work'},
          ],
          'links': [],
        },
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('• Went to MIT'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "that's not right");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('• Went to MIT'), findsNothing);
    expect(find.text('• Works at Acme'), findsOneWidget);
  });

  testWidgets(
      'no correction affordance on the summary or facts of a report about '
      'someone else', (tester) async {
    final api = _api({
      'name': 'Dana Reyes',
      'is_self': false,
      'target_uid': 'u_dana',
      'digest': {
        'name': 'Dana Reyes',
        'summary': 'Marine biologist.',
        'facts': [
          {'id': 'aaa111', 'claim': 'Works at the Oceanário',
           'category': 'work', 'confidence': 'high'},
        ],
        'links': [],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(reportId: 'uid_u_dana', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Marine biologist.'));
    await tester.pumpAndSettle();
    expect(find.text('Correct with Ayma'), findsNothing);

    await tester.tap(find.text('• Works at the Oceanário'));
    await tester.pumpAndSettle();
    expect(find.text('Correct with Ayma'), findsNothing);
  });

  testWidgets('a capped fact correction shows the reload pill and leaves the '
      'claim unchanged', (tester) async {
    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrect(
      {
        'name': 'Suhail Pallath',
        'is_self': true,
        'digest': {
          'name': 'Suhail Pallath',
          'summary': 'x',
          'facts': [
            {'id': 'aaa111', 'claim': 'Went to MIT', 'category': 'education'},
          ],
          'links': [],
        },
      },
      corrections,
      reply: (req) => {'usage_capped': true},
    );

    await tester.pumpWidget(MaterialApp(
      home: DeepDiveReportScreen(
          reportId: 'name_suhail-pallath', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('• Went to MIT'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fix it');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.text('Reload credits'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('• Went to MIT'), findsOneWidget);
  });
}
