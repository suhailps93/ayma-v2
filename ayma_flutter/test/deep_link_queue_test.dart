import 'package:ayma_flutter/core/dag/launch_intent_resolver.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/deep_link_queue.dart';
// fake_async (a transitive dep) lets the navigation-settled ceiling elapse
// deterministically instead of waiting 12 real seconds.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
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

    test(
        'NOTE 279 defect 3: awaitNavigationSettled proceeds after the ceiling '
        'when the splash never signals a settle (no indefinite deadlock)', () {
      fakeAsync((async) {
        queue.resetForTest();
        var done = false;
        queue.awaitNavigationSettled().then((_) => done = true);

        // Well before the ceiling it is still waiting for the splash.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(done, isFalse);

        // Past the ceiling it falls through rather than hang the deep link
        // forever behind a splash wedged in the /splash⇄/signin loop.
        async.elapse(DeepLinkQueue.navigationSettledCeiling);
        async.flushMicrotasks();
        expect(done, isTrue);
      });
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

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const _Dummy()),
          GoRoute(
            path: SignInScreen.path,
            builder: (_, __) => const _Dummy(),
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
