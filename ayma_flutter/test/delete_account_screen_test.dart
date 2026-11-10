import 'dart:convert';

import 'package:ayma_flutter/screens/delete_account_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Harness {
  _Harness({int status = 200}) {
    auth = MockFirebaseAuth(
        signedIn: true, mockUser: MockUser(uid: 'u1', email: 'a@b.co'));
    api = ApiClient(
      auth: auth,
      httpClient: MockClient((req) async {
        deletePaths.add(req.url.path);
        return http.Response(jsonEncode({'ok': status == 200}), status);
      }),
    );
  }

  late final MockFirebaseAuth auth;
  late final ApiClient api;
  final deletePaths = <String>[];
  int pushCleared = 0;

  Widget app() => MaterialApp.router(
        theme: AymaTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/home',
          routes: [
            GoRoute(
              path: '/home',
              builder: (c, s) => Scaffold(
                body: TextButton(
                  onPressed: () => c.push(DeleteAccountScreen.path),
                  child: const Text('open'),
                ),
              ),
            ),
            GoRoute(
              path: DeleteAccountScreen.path,
              builder: (c, s) => DeleteAccountScreen(
                api: api,
                auth: auth,
                clearPushToken: () async => pushCleared++,
              ),
            ),
            GoRoute(
              path: '/signin',
              builder: (c, s) => const Scaffold(body: Text('SIGN IN SCREEN')),
            ),
          ],
        ),
      );
}

Future<void> _open(WidgetTester tester, _Harness h) async {
  await tester.pumpWidget(h.app());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('delete stays disabled until the word is typed; confirm deletes '
      'and signs out to the start screen', (tester) async {
    final h = _Harness();
    await _open(tester, h);

    FilledButton button() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);
    expect(find.textContaining('30 days'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'delet');
    await tester.pump();
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    expect(button().onPressed, isNotNull);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(h.deletePaths, ['/account/delete']);
    expect(h.pushCleared, 1);
    expect(h.auth.currentUser, isNull);
    expect(find.text('SIGN IN SCREEN'), findsOneWidget);
  });

  testWidgets('cancel leaves without calling the API or signing out',
      (tester) async {
    final h = _Harness();
    await _open(tester, h);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(DeleteAccountScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(h.deletePaths, isEmpty);
    expect(h.auth.currentUser, isNotNull);
  });

  testWidgets('a server error shows a message and keeps the user signed in',
      (tester) async {
    final h = _Harness(status: 502);
    await _open(tester, h);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't delete your account"), findsOneWidget);
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    expect(h.pushCleared, 0);
    expect(h.auth.currentUser, isNotNull);

    // Jobs defect 1: the error text reads in the derived errorText token
    // (4.5+ on bg), not the raw AymaColors.error (4.24/4.16, sub-floor).
    final errFinder = find.textContaining("Couldn't delete your account");
    final ac = tester.element(errFinder).ac;
    expect(tester.widget<Text>(errFinder).style!.color, ac.errorText);
    expect(tester.widget<Text>(errFinder).style!.color, isNot(AymaColors.error));
  });

  testWidgets('an expired sign-in (401) asks the user to sign in again',
      (tester) async {
    final h = _Harness(status: 401);
    await _open(tester, h);

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('sign-in has expired'), findsOneWidget);
    expect(h.auth.currentUser, isNotNull);
  });
}
