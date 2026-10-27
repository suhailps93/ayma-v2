import 'dart:convert';

import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
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
}
