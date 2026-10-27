import 'dart:convert';

import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/dev_panel_session.dart';
import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
          builder: (_, __) => SplashScreen(
            apiClient: _api(sessionMode),
            auth: MockFirebaseAuth(signedIn: true),
          ),
        ),
        GoRoute(path: '/signin', builder: (_, __) => const _Marker('signin')),
        GoRoute(path: '/chat', builder: (_, __) => const _Marker('chat')),
        GoRoute(
            path: '/preboarding',
            builder: (_, __) => const _Marker('preboarding')),
        GoRoute(path: '/', builder: (_, __) => const _Marker('shell')),
        GoRoute(
            path: '/recover', builder: (_, __) => const _Marker('recover')),
        GoRoute(path: '/tour', builder: (_, __) => const _Marker('tour')),
      ],
    );

class _Marker extends StatelessWidget {
  const _Marker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text('screen:$name'));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  testWidgets(
      'sets the splash screen context while /bootstrap is in flight',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: _router('active')),
    );
    await tester.pump();
    expect(AppContext.instance.current.value.screen, 'splash');
    await tester.pumpAndSettle();
  });

  group('dev-only feature-tour preview gate', () {
    setUp(() => DevPanelSession.instance.lock());
    tearDown(() async {
      DevPanelSession.instance.lock();
      // Leave the shared global flag clear for any later test.
      await featureTourStoreGlobal.reset();
    });

    testWidgets(
        'a signed-in dev (panel unlocked, flag clear) is routed to the tour',
        (tester) async {
      DevPanelSession.instance.unlock('pw');
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: _router('active')),
      );
      await tester.pumpAndSettle();
      expect(find.text('screen:tour'), findsOneWidget);
      expect(find.text('screen:shell'), findsNothing);
    });

    testWidgets(
        'a normal signed-in user (panel locked) is NOT routed to the tour',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: _router('active')),
      );
      await tester.pumpAndSettle();
      expect(find.text('screen:tour'), findsNothing);
      expect(find.text('screen:shell'), findsOneWidget);
    });
  });
}
