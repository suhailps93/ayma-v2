import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds a splash + router wired to [handler] for `/bootstrap`. A signed-in
/// mock user is used so `_resolve` reaches the bootstrap call (not the
/// not-signed-in early-out).
GoRouter _router(Future<http.Response> Function(http.Request) handler) {
  final api = ApiClient(
    httpClient: MockClient(handler),
    auth: MockFirebaseAuth(signedIn: true),
  );
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, __) =>
            SplashScreen(apiClient: api, auth: MockFirebaseAuth(signedIn: true)),
      ),
      GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
      GoRoute(path: '/chat', builder: (_, __) => const _Marker('chat')),
      GoRoute(
          path: '/preboarding',
          builder: (_, __) => const _Marker('preboarding')),
      GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
      GoRoute(path: '/recover', builder: (_, __) => const _Marker('recover')),
    ],
  );
}

http.Response _activeOk() => http.Response(
      jsonEncode({
        'session_mode': 'active',
        'uid': 'u1',
        'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
      }),
      200,
    );

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}

/// Pumps long enough to exhaust the splash's auto-retry backoff (1s + 3s + 6s)
/// and land on a terminal state, flushing microtasks each step.
Future<void> _settleRetries(WidgetTester tester) async {
  await tester.pump(); // mount + post-frame _resolve()
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // Presentation is immediate unless gated (the engine never reports
  // rasterization under flutter_test) — see SplashFirstPaint.resetForTest.
  setUp(SplashFirstPaint.resetForTest);

  testWidgets(
      'bootstrap network failure shows Retry and does NOT route to sign-in',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(
          (req) async => throw http.ClientException('Failed host lookup'),
        ),
      ),
    );
    await _settleRetries(tester);

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('screen:signin'), findsNothing);
    // Still on the splash — the session was not lost.
    expect(find.byType(SplashErrorView), findsOneWidget);
  });

  testWidgets('tapping Retry re-runs resolve and routes on success',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router((req) async {
          // The boot wake-ping (`GET /health`) is not a bootstrap attempt — it
          // must not consume the counter that drives this scenario.
          if (req.url.path == '/health') {
            return http.Response('{"status":"ok"}', 200);
          }
          calls++;
          // Fail every automatic attempt; succeed once the user taps Retry.
          if (calls <= SplashScreen.maxStartupAttempts) {
            throw http.ClientException('Failed host lookup');
          }
          return _activeOk();
        }),
      ),
    );
    await _settleRetries(tester);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('screen:shell'), findsOneWidget);
  });

  testWidgets('success path routes past the splash unchanged', (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: _router((req) async => _activeOk())),
    );
    await tester.pumpAndSettle();
    expect(find.text('screen:shell'), findsOneWidget);
  });

  testWidgets('genuine auth failure (401) routes to sign-in, not Retry',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(
          (req) async => http.Response(
              jsonEncode({'detail': 'token expired'}), 401),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('screen:signin'), findsOneWidget);
    expect(find.byType(SplashErrorView), findsNothing);
  });

  testWidgets(
      'token timeout (flaky DNS reaching Firebase) retries then shows Retry — '
      'never signs the user out', (tester) async {
    await tester.pumpWidget(
      _appWith(
        _BootstrapThrows(
          ApiException('Network timed out preparing the request.'),
        ),
        MockFirebaseAuth(signedIn: true),
      ),
    );
    await _settleRetries(tester);

    expect(find.byType(SplashErrorView), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('screen:signin'), findsNothing);
  });

  testWidgets(
      'broken auth session (keystore/decrypt failure) signs out and routes to '
      'sign-in — not Retry, not a retry loop', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true);
    await tester.pumpWidget(
      _appWith(
        _BootstrapThrows(
          AuthSessionException('Auth token unreadable: decrypt'),
        ),
        auth,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('screen:signin'), findsOneWidget);
    expect(find.byType(SplashErrorView), findsNothing);
    // The unusable session was cleared so sign-in can replace it.
    expect(auth.currentUser, isNull);
  });

  testWidgets(
      'overall watchdog surfaces Retry when startup hangs past the deadline',
      (tester) async {
    await tester.pumpWidget(
      _appWith(_BootstrapHangs(), MockFirebaseAuth(signedIn: true)),
    );
    await tester.pump(); // mount + post-frame _resolve (which then hangs)

    // Nothing has navigated and the call never returns — the watchdog must
    // still end the orb and show Retry by the overall deadline.
    await tester.pump(SplashScreen.startupDeadline + const Duration(seconds: 1));

    expect(find.byType(SplashErrorView), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('screen:signin'), findsNothing);
  });

  testWidgets(
      'slow/cold backend: first calls time out then succeed — stays on LOADING '
      'and auto-recovers into the app, NEVER a hard-fail on the first timeout',
      (tester) async {
    final api = _BootstrapColdStart(failures: 2);
    await tester.pumpWidget(_appWith(api, MockFirebaseAuth(signedIn: true)));

    // After the first attempt times out, the splash schedules an auto-retry:
    // it must show the LOADING orb (reconnecting), never the Retry hard-fail.
    await tester.pump(); // mount + post-frame _resolve → 1st attempt fails
    expect(find.byType(SplashLoading), findsOneWidget);
    expect(find.byType(SplashErrorView), findsNothing);

    // Ride out the exponential backoff (1s then 2s) across the two cold-start
    // failures into the third, successful attempt — all well inside the budget.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();

    // Recovered into the app with no hard-fail screen ever shown.
    expect(find.text('screen:shell'), findsOneWidget);
    expect(find.byType(SplashErrorView), findsNothing);
    expect(api.calls, 3);
  });
}

/// A [MockClient] that answers the unauthenticated boot wake-ping (`GET
/// /health`) with 200, so the `_appWith` subclasses exercise the real
/// [ApiClient.wakeUp] path without a live network call leaking a pending timer
/// into the widget-test harness.
MockClient _okHealthClient() => MockClient(
      (req) async => http.Response('{"status":"ok","service":"ayma-api"}', 200),
    );

/// A router (as [_router]) but wired to an explicit [api] and [auth] so a test
/// can inject a custom [ApiClient.bootstrap] behaviour and hold the auth to
/// assert sign-out.
Widget _appWith(ApiClient api, FirebaseAuth auth) {
  return MaterialApp.router(
    routerConfig: GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(apiClient: api, auth: auth),
        ),
        GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
        GoRoute(path: '/chat', builder: (_, __) => const _Marker('chat')),
        GoRoute(
            path: '/preboarding',
            builder: (_, __) => const _Marker('preboarding')),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
        GoRoute(path: '/recover', builder: (_, __) => const _Marker('recover')),
      ],
    ),
  );
}

/// An [ApiClient] whose `bootstrap` always throws [error] — to drive the
/// splash's failure classification directly (network vs broken session).
class _BootstrapThrows extends ApiClient {
  _BootstrapThrows(this.error)
      : super(
          auth: MockFirebaseAuth(signedIn: true),
          httpClient: _okHealthClient(),
        );

  final Object error;

  @override
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
    String practiceReturnSessionId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async =>
      throw error;
}

/// An [ApiClient] whose `bootstrap` never completes — to prove the splash's
/// overall watchdog ends the spinner even when nothing else does.
class _BootstrapHangs extends ApiClient {
  _BootstrapHangs()
      : super(
          auth: MockFirebaseAuth(signedIn: true),
          httpClient: _okHealthClient(),
        );

  @override
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
    String practiceReturnSessionId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) =>
      Completer<BootstrapResult>().future;
}

/// An [ApiClient] whose `bootstrap` throws a cold-start-class network timeout
/// for its first [failures] attempts, then succeeds — models a scaled-to-zero
/// backend that is slow/unreachable on the first call(s) and then warms up.
class _BootstrapColdStart extends ApiClient {
  _BootstrapColdStart({required this.failures})
      : super(
          auth: MockFirebaseAuth(signedIn: true),
          httpClient: _okHealthClient(),
        );

  final int failures;
  int calls = 0;

  @override
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
    String practiceReturnSessionId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async {
    calls++;
    if (calls <= failures) {
      throw ApiException('Network timed out reaching Ayma.');
    }
    return const BootstrapResult(
      sessionMode: 'active',
      livekitUrl: 'wss://x',
      livekitToken: 't',
      room: 'r',
    );
  }
}
