import 'dart:convert';

import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(Map<String, dynamic> body) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/deep-dive-report/')) {
          return http.Response(jsonEncode(body), 200);
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
    // Only the verified one is shown, with its match score.
    expect(find.text('match 82%'), findsOneWidget);
    expect(find.text('unverified'), findsNothing);
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
}
