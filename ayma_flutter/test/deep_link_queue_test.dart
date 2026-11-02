import 'dart:async';

import 'package:ayma_flutter/core/dag/launch_intent_resolver.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/deep_link_queue.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  group('DeepLinkQueue Hard Auth Invariant', () {
    late DeepLinkQueue queue;

    setUp(() {
      queue = DeepLinkQueue.instance;
      queue.resetForTest();
    });

    test('Hard Auth Invariant — deep link pauses until ensureAuthReady completes',
        () async {
      final auth = MockFirebaseAuth();
      final authService = AuthService(auth: auth);
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const _Dummy()),
        GoRoute(path: '/signin', builder: (_, __) => const _Dummy()),
      ]);

      var navigatedPath = '';
      final intent = const DmDeepLinkIntent(
        recipientUid: 'target_u',
        rawPayload: {'deep_link': 'profile/target_u'},
      );

      final handleFuture = queue.handleIntent(
        intent,
        router: router,
        authService: authService,
        navigate: (path) => navigatedPath = path,
      );

      // Deep link has not routed because ensureAuthReady is pending
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(navigatedPath, isEmpty);

      // Restore user session and mark navigation settled
      authService.notifyAuthSessionRestored(MockUser(uid: 'my_uid_123'));
      queue.notifyNavigationSettled();
      await handleFuture;

      expect(navigatedPath, equals('/dm/my_uid_123__target_u'));
    });

    test('Zero Empty UID — asserts myUid is never empty in deep link routing',
        () async {
      expect(
        () => queue.drainPostAuth('', navigate: (_) {}),
        returnsNormally, // Silently ignores empty UID without calling sortedPairKey
      );
    });

    test('Unauthenticated Stash & Drain — routes to /signin and replays on auth',
        () async {
      final auth = MockFirebaseAuth();
      final authService = AuthService(auth: auth);

      var routedLocation = '';
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const _Dummy()),
          GoRoute(
            path: SignInScreen.path,
            builder: (_, __) {
              routedLocation = SignInScreen.path;
              return const _Dummy();
            },
          ),
        ],
      );

      const intent = PaywallDeepLinkIntent(targetPath: '/profile/plan');

      // Unauthenticated session restoration
      authService.notifyAuthSessionRestored(null);

      await queue.handleIntent(
        intent,
        router: router,
        authService: authService,
        navigate: (_) {},
      );

      // Routed to signin, intent stashed
      expect(queue.pendingPostAuthIntent, isNotNull);
      expect(queue.pendingPostAuthIntent, equals(intent));

      // User completes sign-in -> Drain post-auth
      var drainedPath = '';
      queue.notifyNavigationSettled();
      await queue.drainPostAuth('signed_in_user_77', navigate: (path) {
        drainedPath = path;
      });

      expect(drainedPath, equals('/profile/plan'));
      expect(queue.pendingPostAuthIntent, isNull);
    });
  });
}

class _Dummy extends StatelessWidget {
  const _Dummy();
  @override
  Widget build(BuildContext context) => const Placeholder();
}
