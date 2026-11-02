import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// J1 regression (device stack capture, build 454c94c): warm-tapping the self
/// web-search notification navigated into the chat with `appRouter.push('/')`,
/// stacking a SECOND `MainShellScreen` on top of the live one. Both shells
/// mount the same process-wide feature-tour anchor GlobalKey
/// (`TourAnchors.keyFor(homeComposer)`, attached to the chat composer's root)
/// at once — a Flutter "Duplicate GlobalKey" error that retakes the inactive
/// element mid-layout, mutates the composer's `RenderFlex` ("A RenderFlex was
/// mutated in _RenderLayoutBuilder.performLayout") and corrupts the tree so
/// even the go(Home) recovery re-throws.
///
/// The fix (`navigateToRoute`) returns to the root shell with `go` (reuse the
/// single existing shell) instead of `push`. These tests reproduce the exact
/// warm re-navigation — a second shell mounting the composer anchor key while
/// the first is still present — and assert no duplicate-GlobalKey / RenderFlex
/// exception is thrown.
void main() {
  // The anchor key the real composer attaches (chat_composer.dart:292, via
  // ChatScreen.composerAnchorKey = TourAnchors.keyFor(homeComposer)). Using the
  // real key makes the collision faithful: two live mounts of THIS key are the
  // J1 throw.
  Widget shell(String label) => Scaffold(
        body: SizedBox(
          key: TourAnchors.keyFor(TourAnchors.homeComposer),
          child: Text(label),
        ),
      );

  GoRouter buildRouter() => GoRouter(
        initialLocation: MainShellScreen.path,
        routes: [
          GoRoute(
            path: MainShellScreen.path,
            builder: (context, state) => shell('shell'),
          ),
          GoRoute(
            path: '/dm/x',
            builder: (context, state) =>
                const Scaffold(body: Text('sub-route')),
          ),
        ],
      );

  testWidgets(
      'warm re-navigation to the root shell reuses the live shell — no second '
      'MainShellScreen, no duplicate composer-anchor GlobalKey (J1)',
      (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    final router = buildRouter();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // User is deep in a pushed sub-route; the root shell stays mounted
    // (offstage) beneath it, so its composer anchor key is already registered.
    router.push('/dm/x');
    await tester.pumpAndSettle();

    // Warm-tap the web-search notification → it resolves to '/'. The fixed
    // dispatcher must reuse the existing shell, not stack a second one.
    navigateToRoute(MainShellScreen.path, router: router);
    await tester.pumpAndSettle();

    expect(
      errors.where((e) =>
          e.exceptionAsString().contains('Duplicate GlobalKey') ||
          e.exceptionAsString().contains('was mutated')),
      isEmpty,
      reason: 'Re-navigating to the root shell must not stack a second shell '
          '(two live widgets holding TourAnchors.homeComposer).',
    );
    expect(errors, isEmpty, reason: 'No framework exception may be thrown.');
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('sub-route'), findsNothing);
  });
}
