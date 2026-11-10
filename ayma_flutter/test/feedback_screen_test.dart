import 'dart:convert';

import 'package:ayma_flutter/screens/feedback_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PackageInfo.setMockInitialValues(
      appName: 'Ayma',
      packageName: 'com.ayma.ayma_flutter',
      version: '1.30.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('submits a bug report to the unified /feedback/submit',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? sent;
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/feedback/submit') {
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'ok': true, 'id': 'p-1'}), 200);
        }
        return http.Response('no', 404);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: FeedbackScreen(api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Send'), findsOneWidget);
    // Send is inert until there's text.
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('feedback-title-field')), 'Orb flickers');
    await tester.enterText(
        find.byKey(const ValueKey('feedback-body-field')),
        'the orb flickers on messages');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!['kind'], 'bug');
    expect(sent!['body'], 'the orb flickers on messages');
    expect(sent!['title'], 'Orb flickers');
    expect(sent!['source'], 'settings_form');
    expect(sent!['screenshot_paths'], isEmpty);
  });

  testWidgets('switching to Feature changes the submitted kind',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? sent;
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true, 'id': 'p-2'}), 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: FeedbackScreen(api: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Feature'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('feedback-body-field')),
        'add a dark orb option');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(sent!['kind'], 'feature');
    expect(sent!['source'], 'settings_form');
  });

  testWidgets('the Kind SegmentedButton clears the 44 touch floor',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient(
          (req) async => http.Response(jsonEncode({'ok': true}), 200)),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: FeedbackScreen(api: api),
    ));
    await tester.pumpAndSettle();

    // Defect 4: the minimumSize 44 fix keeps the control at the padded 48
    // tap-target height — above the 44 absolute floor in both states.
    final seg = find.byType(SegmentedButton<String>);
    expect(seg, findsOneWidget);
    expect(tester.getSize(seg).height, greaterThanOrEqualTo(44.0));
  });
}
