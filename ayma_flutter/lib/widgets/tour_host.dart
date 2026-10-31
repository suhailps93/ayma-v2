import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../screens/main_shell_screen.dart';
import '../services/tab_request.dart';
import '../services/tour_content.dart';
import '../services/tour_controller.dart';
import 'coach_mark_overlay.dart';

/// Hosts the single interactive feature-tour overlay (§11.2a) at the ROOT of
/// the app — mounted in `MaterialApp.router`'s `builder`, so it sits ABOVE the
/// `Navigator` and every route it pushes. That is the whole point: the old
/// overlay lived inside `MainShellScreen`'s own `Stack`, so the moment a step
/// pushed a sub-page (My story, Appearance, Ayma's settings) on top of the
/// shell, the overlay was torn down / buried and the floating callout vanished
/// (the founder's "when you click to a different page, the pop-up goes away").
/// Here the one overlay stays mounted across pushes and keeps the same callout
/// open as the tour moves between pages.
///
/// It watches [TourController] (which the shell's gate / replay starts) and
/// renders [CoachMarkOverlay] only while a tour is [TourController.active]. When
/// idle it adds nothing to the tree — [child] is returned untouched.
///
/// Navigation-aware: [_prepareStep] is handed to the overlay as `onPrepareStep`
/// and runs before each step is measured. Because every tour anchor lives in
/// the shell (the nav-bar orb/tabs/bell, the chat composer, the Profile rows),
/// it first pops any pushed sub-page back to the shell (`appRouter.go('/')`) so
/// the shell's own keyed widgets are the live, measurable ones, then asks the
/// shell to switch to the step's [TourFeature.tab] (via [TabRequest], the same
/// one-slot hand-off a normal tab switch uses). The overlay then re-acquires
/// the anchor on the now-correct page.
class TourHost extends StatelessWidget {
  const TourHost({super.key, required this.child});

  final Widget child;

  /// Put the app where [feature]'s anchor lives before it's measured: pop any
  /// pushed sub-page back to the shell, then switch to its tab. Safe no-ops when
  /// already there (`go('/')` just stays; a `TabRequest` for the current tab is
  /// ignored by the shell).
  static void _prepareStep(TourFeature feature) {
    final path = appRouter.routeInformationProvider.value.uri.path;
    if (path != MainShellScreen.path) {
      appRouter.go(MainShellScreen.path);
    }
    final tab = feature.tab;
    if (tab != null) TabRequest.instance.request(tab);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: TourController.instance,
      child: child,
      builder: (context, child) {
        final controller = TourController.instance;
        final features = controller.features;
        if (features == null) return child!;
        return Stack(
          children: [
            child!,
            // The overlay fills the whole window, above every route. Back while
            // the tour is up is handled by `MainShellScreen`'s `PopScope` (it
            // has a `Router` ancestor, which this builder-level context does
            // not — a `BackButtonListener` here throws), where it skips the
            // tour via `TourController`.
            Positioned.fill(
              child: CoachMarkOverlay(
                key: const ValueKey('root-coach-mark'),
                features: features,
                spotlight: controller.spotlight,
                store: controller.store,
                onPrepareStep: _prepareStep,
                onFinish: controller.finish,
              ),
            ),
          ],
        );
      },
    );
  }
}
