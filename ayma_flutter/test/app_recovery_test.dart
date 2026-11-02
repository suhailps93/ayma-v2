import 'package:ayma_flutter/core/app_recovery.dart';
import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// J1: QA tapped "Go back" on the chromeless "Something didn't load" panel that
/// had replaced the pushed `/deep-dive/:id` route, and stayed stranded — the
/// recovery did NOT land on a known-good screen (force-stop was the only exit).
/// [recoverAppRoot] must CLEAR the throwing route and settle the router on Home,
/// not merely rebuild the current (throwing) route.
void main() {
  tearDown(() {
    // Leave the global router at Home for any later test in the run.
    appRouter.go(MainShellScreen.path);
  });

  testWidgets(
      'recoverAppRoot clears the throwing route and lands the router on Home',
      (tester) async {
    // Stranded on the pushed deep-dive route that threw.
    appRouter.go('/deep-dive/name_test');
    expect(
      appRouter.routeInformationProvider.value.uri.path,
      '/deep-dive/name_test',
      reason: 'precondition: router is on the throwing /deep-dive route',
    );

    recoverAppRoot();
    // Fire the post-frame re-assert that guards against a re-mounted Router
    // restoring the stale /deep-dive matchlist.
    await tester.pump();

    expect(
      appRouter.routeInformationProvider.value.uri.path,
      MainShellScreen.path,
      reason: 'after recovery the current route must be Home, not the route '
          'that threw',
    );
  });

  testWidgets('recoverAppRoot bumps the app-root epoch to force a rebuild',
      (tester) async {
    final before = appRecoveryEpoch.value;
    recoverAppRoot();
    await tester.pump();
    expect(appRecoveryEpoch.value, greaterThan(before),
        reason: 'recovery must re-mount the router subtree, not no-op');
  });
}
