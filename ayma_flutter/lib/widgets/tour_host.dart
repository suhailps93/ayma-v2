import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../screens/main_shell_screen.dart';
import '../services/guided_tour_controller.dart';
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
    // A typing-allowed step (the composer) must never yank the keyboard away:
    // the user may already be typing while the tour re-presents it, and this
    // runs before every step.
    if (!feature.typingAllowed) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    try {
      var safety = 10;
      while (appRouter.canPop() && safety-- > 0) {
        appRouter.pop();
      }
      final path = appRouter.routeInformationProvider.value.uri.path;
      if (path != MainShellScreen.path) {
        appRouter.go(MainShellScreen.path);
      }
    } catch (_) {}
    final tab = feature.tab;
    if (tab != null) TabRequest.instance.request(tab);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // Watch both the passive feature tour and the Ayma-driven tour; only one
      // renders at a time (driven takes priority — it's user-initiated).
      animation: Listenable.merge(
        [TourController.instance, GuidedTourController.instance],
      ),
      child: child,
      builder: (context, child) {
        final guided = GuidedTourController.instance;
        final driven = guided.step;
        if (driven != null) {
          return Stack(
            children: [child!, Positioned.fill(child: _drivenOverlay(driven))],
          );
        }
        // While an Ayma-driven tour session is running (even BETWEEN steps —
        // the moment after a tap dismisses one step and before the backend
        // sends the next), never show the passive coach-mark tour: it would
        // flash its own card over a different anchor and read as a "wrong
        // highlight"/stray dialog (founder, 2026-11-03). The driven tour owns
        // the screen until it ends.
        if (guided.sessionActive) return child!;
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

  /// The Ayma-driven tour's single spotlighted step (§11.2b): rendered through
  /// [CoachMarkOverlay] with callout card (headline, say text, counter, Skip
  /// tour and Next CTAs). Keyed by the step's token so each pushed step gets a
  /// fresh measure.
  /// Prepare for a DRIVEN step: deliberately NO navigation. The rewire
  /// (founder, 2026-11-07) makes the backend + client verify the user is
  /// already on the step's screen BEFORE the step is shown (the tour_step
  /// ack), so the host must not pop routes or switch tabs on the tour's
  /// behalf — that blind navigation was the old tour's core flaw. Only
  /// drop focus so the spotlight reads clean (never for the composer
  /// step, where the user may be typing).
  static void _prepareDrivenStep(TourFeature feature) {
    if (!feature.typingAllowed) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  Widget _drivenOverlay(GuidedTourStep step) {
    return CoachMarkOverlay(
      key: ValueKey('guided-tour-${step.token}'),
      features: [step.feature],
      stepIndex: step.index,
      stepTotal: step.total,
      chromeless: false,
      onPrepareStep: _prepareDrivenStep,
      onFinish: GuidedTourController.instance.endSession,
      onAnchorShown: step.onShown,
      onAnchorAbsent: step.onAbsent,
      onAnchorTapped: step.onTapped,
      onSkipPressed: step.onSkip,
      onStopPressed: step.onStop,
    );
  }
}
