import 'dart:convert';

import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(String sessionMode) {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((req) async {
    if (req.url.path == '/bootstrap') {
      if (sessionMode == 'recovery') {
        return http.Response(
            jsonEncode({'recovery_required': true, 'uid': 'u1'}), 200);
      }
      if (sessionMode == 'capped-active') {
        // Out of credits: server still returns the real session_mode, just no
        // LiveKit creds. The client must route on it, not fall to marketing.
        return http.Response(
            jsonEncode({
              'usage_capped': true,
              'uid': 'u1',
              'session_mode': 'active',
            }),
            200);
      }
      return http.Response(
        jsonEncode({
          'session_mode': sessionMode,
          'uid': 'u1',
          'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
        }),
        200,
      );
    }
    return http.Response('nope', 404);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

GoRouter _router(String sessionMode) => GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(apiClient: _api(sessionMode)),
        ),
        GoRoute(path: '/chat', builder: (_, __) => const _Marker('chat')),
        GoRoute(
            path: '/preboarding',
            builder: (_, __) => const _Marker('preboarding')),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
        GoRoute(
            path: '/recover', builder: (_, __) => const _Marker('recover')),
      ],
    );

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}

void main() {
  for (final (mode, marker) in const [
    ('marketing', 'screen:chat'),
    ('interview', 'screen:preboarding'),
    ('active', 'screen:shell'),
    ('recovery', 'screen:recover'),
    ('capped-active', 'screen:shell'),
  ]) {
    testWidgets('session_mode "$mode" routes past the splash', (tester) async {
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: _router(mode)),
      );
      await tester.pumpAndSettle();
      expect(find.text(marker), findsOneWidget);
    });
  }
}
