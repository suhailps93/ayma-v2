import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/models/boot_config.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup audit §3.3: the splash's 2s auth-wait could return a null user when
/// a signed-in user's KeyStore/Keychain session is still restoring, bouncing
/// them to /signin. With a cached BootConfig on the device the splash now
/// paints that last-known route instead, and only corrects to /signin if auth
/// genuinely never restores.

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}

/// An AuthService whose restore takes [delay] (longer than the splash's 2s
/// wait) then yields [user] — or never completes when [delay] is null.
class _SlowAuth extends AuthService {
  _SlowAuth({required this.user, this.delay}) : super(auth: MockFirebaseAuth());
  final User? user;
  final Duration? delay;
  @override
  Future<User?> ensureAuthReady() {
    final d = delay;
    if (d == null) return Completer<User?>().future; // never restores
    return Future<User?>.delayed(d, () => user);
  }
}

http.Response _activeOk() => http.Response(
      jsonEncode({
        'session_mode': 'active',
        'uid': 'u1',
        'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
      }),
      200,
    );

GoRouter _router(SplashScreen splash) => GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => splash),
        GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
      ],
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(); // mount + post-frame _resolve()
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  setUp(SplashFirstPaint.resetForTest);
  setUp(StartupDeadline.resetForTest);

  void seedConfig() {
    final cfg = BootConfig(
      uid: 'u1',
      sessionMode: 'active',
      entryRoute: '/',
      cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    SharedPreferences
        .setMockInitialValues({'boot_config:u1': jsonEncode(cfg.toJson())});
    ReportCache.instance.resetForTest();
  }

  testWidgets(
      'auth-wait timeout WITH a cached BootConfig navigates the cached route, '
      'never sign-in', (tester) async {
    seedConfig();
    final splash = SplashScreen(
      // The background bootstrap mints tokens off a restored session.
      apiClient: ApiClient(
          httpClient: MockClient((_) async => _activeOk()),
          auth: MockFirebaseAuth(signedIn: true)),
      auth: MockFirebaseAuth(), // the pre-restore snapshot: currentUser null
      authService:
          _SlowAuth(user: MockUser(uid: 'u1'), delay: const Duration(seconds: 3)),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(splash)));
    await _settle(tester);

    expect(find.text('screen:signin'), findsNothing,
        reason: 'a returning user with a slow restore must not be bounced');
    expect(find.text('screen:shell'), findsOneWidget);
  });

  testWidgets('auth-wait timeout with NO cached config falls back to sign-in',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    ReportCache.instance.resetForTest();
    final splash = SplashScreen(
      apiClient: ApiClient(
          httpClient: MockClient((_) async => _activeOk()),
          auth: MockFirebaseAuth()),
      auth: MockFirebaseAuth(),
      authService: _SlowAuth(user: null, delay: null), // never restores
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(splash)));
    await _settle(tester);

    expect(find.text('screen:signin'), findsOneWidget);
  });

  testWidgets(
      'cached route is painted but auth never restores → recovery corrects to '
      'sign-in honestly', (tester) async {
    seedConfig();
    final splash = SplashScreen(
      apiClient: ApiClient(
          httpClient: MockClient((_) async => _activeOk()),
          auth: MockFirebaseAuth()),
      auth: MockFirebaseAuth(),
      authService: _SlowAuth(user: null, delay: null), // never restores
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(splash)));
    await _settle(tester);

    expect(find.text('screen:signin'), findsOneWidget);
  });
}
