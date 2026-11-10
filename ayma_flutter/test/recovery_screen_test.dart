import 'dart:convert';

import 'package:ayma_flutter/screens/recovery_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/biometric_consent.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'recover button calls /account/recover, clears the recovery gate, then '
      're-bootstraps via splash (B9)', (tester) async {
    // Pre-condition: the session was held behind the recovery gate.
    RecoveryRequiredState.instance.markRequired();
    addTearDown(RecoveryRequiredState.instance.clear);

    final paths = <String>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    final router = GoRouter(
      initialLocation: '/recover',
      routes: [
        GoRoute(
          path: '/recover',
          builder: (_, __) => RecoveryScreen(apiClient: api),
        ),
        // Recovery must re-run startup through the splash so session_mode and
        // the restored profile are re-read — NOT a blind jump to '/'.
        GoRoute(
          path: '/splash',
          builder: (_, __) => const Scaffold(body: Text('splash')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
    await tester.tap(find.text('Recover my account'));
    await tester.pumpAndSettle();

    expect(paths, ['/account/recover']);
    expect(find.text('splash'), findsOneWidget);
    expect(RecoveryRequiredState.instance.required, isFalse);
  });

  // --- Jobs pass (cluster 11) spacing/color assertions ---

  testWidgets('recovery sits at the 20 screen edge with a 24 body->Recover '
      'gap (jobs defects 4 + 5)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecoveryScreen()));
    await tester.pumpAndSettle();

    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.padding, const EdgeInsets.all(20));

    // The body -> Recover gap is now 24 (on the 8/12/16/24 rhythm); the old
    // off-rhythm 28 must be gone from the column.
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 24),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 28),
      findsNothing,
    );
  });

  testWidgets('recovery error line uses the text-safe errorText token '
      '(jobs defect 6)', (tester) async {
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient(
        (req) async => http.Response(jsonEncode({'detail': 'nope'}), 500),
      ),
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: RecoveryScreen(apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Recover my account'));
    await tester.pumpAndSettle();

    final errorText = tester.widget<Text>(
      find.textContaining('Recovery failed'),
    );
    expect(errorText.style?.color, AymaTokens.dark.errorText);
    // Must NOT be the raw error token (the pre-fix color).
    expect(errorText.style?.color, isNot(AymaColors.error));
  });
}
