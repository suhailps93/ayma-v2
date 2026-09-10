import 'dart:convert';

import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
}
