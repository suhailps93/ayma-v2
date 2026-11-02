import 'package:flutter/material.dart';

import '../core/app_recovery.dart';
import '../services/error_reporting.dart';
import '../theme.dart';

/// App-wide replacement for Flutter's default **red** [ErrorWidget].
///
/// When a widget's `build` throws — e.g. an element-tree assertion during a
/// failed data-load rebuild (GATE-RED: the chat history-load failure the
/// founder hit) — Flutter otherwise paints a full-screen solid-red error block.
/// Wired as `ErrorWidget.builder` in `main`, this renders a calm, neutral
/// fallback instead, so a localized build failure can never show a user the red
/// block regardless of its root cause.
///
/// The error is NOT swallowed: `FlutterError.onError` (loud log + Crashlytics)
/// fires independently of `ErrorWidget.builder`, so the fleet still sees and
/// reports every such failure. Applied in all modes on purpose — the app's
/// debug builds are what non-developer testers and the founder run, and they
/// must never see the raw red screen; developers still get the console stack.
///
/// Built to be robust high in the tree: it brings its own [Directionality] and
/// a [Material] canvas (so [Text] never shows the yellow "no Material" debug
/// underlines — SWEEP91-J1R S2, QA saw them), hardcoded neutral colors, and
/// avoids `Scaffold`/`Theme`/`MediaQuery` lookups, since an ancestor of those
/// may be exactly what failed to build.
Widget gracefulErrorWidget(FlutterErrorDetails details) {
  // Debug/profile only: dump the throwing widget + stack to the console so the
  // exact build-throw behind this fallback is capturable in `adb logcat`. This
  // path fires independently of `FlutterError.onError`, so we dump here too —
  // some throws reach the ErrorWidget.builder without a loud onError. Gated off
  // release inside [dumpBuildErrorToConsole]; release/Crashlytics is unchanged.
  dumpBuildErrorToConsole(details, source: 'ErrorWidget.builder');
  // Context-free (an ancestor Theme may be exactly what failed), so use the
  // app's dark-palette compile-time constants from theme.dart directly rather
  // than a Theme.of(context) lookup.
  const bg = AymaColors.darkBg;
  const fg = AymaColors.darkFg;
  const muted = AymaColors.darkFgMute;
  // Directionality + a Material canvas are both brought in-house: the failed
  // subtree can be the route's own Scaffold (no Material above the Text ->
  // yellow underlines) or the whole app (no Directionality -> an assert). This
  // widget stands alone under either.
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Material(
      color: bg,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.cloud_off_rounded, color: muted, size: 36),
            SizedBox(height: 14),
            Text(
              "Something didn't load",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: fg,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Please go back and try again in a moment.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 14, height: 1.3),
            ),
            // This fallback can replace a whole route's chrome (AppBar + back
            // button included), or the whole app tree, when a build throws —
            // leaving a chromeless screen that Android's system BACK can't pop,
            // a dead end only force-stop recovered from (SWEEP91-J1R S2). The
            // "Go back" affordance below guarantees a way out, and crucially it
            // RECOVERS THE FRAME even when the Router itself was torn out (see
            // [recoverAppRoot]) — not just when a single route can be popped.
            SizedBox(height: 22),
            _GoBackButton(),
          ],
        ),
      ),
    ),
  );
}

/// A context-free recovery button for [gracefulErrorWidget] — no
/// Theme/Navigator-of-context lookups (any of them may be the thing that
/// failed to build). It calls [recoverAppRoot], which resets the route Home
/// AND force-rebuilds the app root, so the frame changes even when the global
/// router's delegate was unmounted by the failure. Guarded so a tap can never
/// itself throw out of the error screen.
class _GoBackButton extends StatelessWidget {
  const _GoBackButton();

  @override
  Widget build(BuildContext context) {
    const fg = AymaColors.darkFg;
    const muted = AymaColors.darkFgMute;
    return GestureDetector(
      onTap: recoverAppRoot,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: muted),
        ),
        child: const Text(
          'Go back',
          style: TextStyle(
            color: fg,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
