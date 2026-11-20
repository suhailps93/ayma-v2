import 'package:ayma_flutter/core/firebase_config_guard.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Scout NOTE 263: a mis-built APK whose NATIVE Firebase project (ayma-ai, prod)
// differs from the Dart firebase_options project (ayma-staging) mints
// wrong-project tokens, so sign-in succeeds but every authed call 401s and the
// splash loops the user through sign-in. These pin both the pure detector and
// the splash's honest-error response on that exact path.

void main() {
  group('firebaseProjectMismatchMessage', () {
    test('matching projects are healthy (null)', () {
      expect(
        firebaseProjectMismatchMessage(
          effectiveProjectId: 'ayma-staging',
          intendedProjectId: 'ayma-staging',
        ),
        isNull,
      );
    });

    test('Scout NOTE 263 case: native prod vs Dart staging is flagged', () {
      final msg = firebaseProjectMismatchMessage(
        effectiveProjectId: 'ayma-ai',
        intendedProjectId: 'ayma-staging',
      );
      expect(msg, isNotNull);
      expect(msg, contains('ayma-ai'));
      expect(msg, contains('ayma-staging'));
      expect(msg, contains('401'));
    });

    test('an empty id on either side is never a false positive', () {
      expect(
        firebaseProjectMismatchMessage(
          effectiveProjectId: '',
          intendedProjectId: 'ayma-staging',
        ),
        isNull,
      );
      expect(
        firebaseProjectMismatchMessage(
          effectiveProjectId: 'ayma-staging',
          intendedProjectId: '',
        ),
        isNull,
      );
    });

    test('surrounding whitespace does not trip a mismatch', () {
      expect(
        firebaseProjectMismatchMessage(
          effectiveProjectId: ' ayma-staging ',
          intendedProjectId: 'ayma-staging',
        ),
        isNull,
      );
    });
  });

  group('splash surfaces the config mismatch as an honest, blocking error', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    setUp(SplashFirstPaint.resetForTest);
    setUp(StartupDeadline.resetForTest);
    setUp(FirebaseConfigGuard.instance.resetForTest);
    tearDown(FirebaseConfigGuard.instance.resetForTest);

    // A bootstrap client that fails the test if it is ever called: a detected
    // mismatch must short-circuit BEFORE any authed network, exactly as a
    // wrong-project token would otherwise 401 against the real backend.
    ApiClient neverCalledApi() => ApiClient(
          httpClient: MockClient((req) async {
            fail('no authed request may fire on a Firebase project mismatch: '
                '${req.url.path}');
            // ignore: dead_code
            return http.Response('', 500);
          }),
          auth: MockFirebaseAuth(signedIn: true),
        );

    GoRouter router() => GoRouter(
          initialLocation: '/splash',
          routes: [
            GoRoute(
              path: '/splash',
              builder: (_, __) => SplashScreen(
                apiClient: neverCalledApi(),
                auth: MockFirebaseAuth(signedIn: true),
              ),
            ),
            GoRoute(
                path: '/signin', builder: (_, __) => const _Marker('signin')),
            GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
          ],
        );

    testWidgets('shows the diagnostic and does not loop into sign-in',
        (tester) async {
      FirebaseConfigGuard.instance.mismatch = firebaseProjectMismatchMessage(
        effectiveProjectId: 'ayma-ai',
        intendedProjectId: 'ayma-staging',
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router()));
      await tester.pumpAndSettle();

      // The honest error (Retry affordance) is shown — not a silent spinner,
      // and not a bounce to sign-in or the shell.
      expect(find.textContaining('401'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('screen:signin'), findsNothing);
      expect(find.text('screen:shell'), findsNothing);
    });

    testWidgets('a healthy build (no mismatch) does not show the diagnostic',
        (tester) async {
      // mismatch stays null (reset in setUp): the guard must be transparent.
      await tester.pumpWidget(MaterialApp.router(routerConfig: _healthyRouter()));
      await tester.pumpAndSettle();
      expect(find.textContaining('misconfigured'), findsNothing);
    });
  });
}

// A healthy splash whose bootstrap routes straight to the shell — asserts the
// guard adds no friction when the projects agree.
GoRouter _healthyRouter() => GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(
            apiClient: ApiClient(
              httpClient: MockClient((req) async {
                if (req.url.path == '/bootstrap') {
                  return http.Response(
                    '{"session_mode":"active","uid":"u1",'
                    '"livekit":{"token":"t","url":"wss://x","room":"r"}}',
                    200,
                  );
                }
                return http.Response('nope', 404);
              }),
              auth: MockFirebaseAuth(signedIn: true),
            ),
            auth: MockFirebaseAuth(signedIn: true),
          ),
        ),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
        GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
      ],
    );

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}
