import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../screens/main_shell_screen.dart';
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
/// hardcoded neutral colors, and avoids `Scaffold`/`Theme`/`MediaQuery`
/// lookups, since an ancestor of those may be exactly what failed to build.
Widget gracefulErrorWidget(FlutterErrorDetails details) {
  // Context-free (an ancestor Theme may be exactly what failed), so use the
  // app's dark-palette compile-time constants from theme.dart directly rather
  // than a Theme.of(context) lookup.
  const bg = AymaColors.darkBg;
  const fg = AymaColors.darkFg;
  const muted = AymaColors.darkFgMute;
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      color: bg,
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
          // button included) when the build threw high in the subtree, leaving
          // a chromeless screen that Android's system BACK sometimes can't pop
          // — a dead end only force-stop recovered from (Scout SWEEP91 S2).
          // A self-contained, context-free "Go back" affordance guarantees a
          // way out regardless: it pops the top route, or returns Home when
          // there's nothing to pop. Built WITHOUT Material/Theme (an ancestor
          // of those may be exactly what failed) — a plain tappable box.
          SizedBox(height: 22),
          _GoBackButton(),
        ],
      ),
    ),
  );
}

/// A context-free recovery button for [gracefulErrorWidget] — no
/// Material/Theme/Navigator-of-context lookups (any of them may be the thing
/// that failed to build). It drives the global [appRouter] directly: pop the
/// stranded route when possible, else go Home. Every call is guarded so a tap
/// can never itself throw out of the error screen.
class _GoBackButton extends StatelessWidget {
  const _GoBackButton();

  void _recover() {
    try {
      if (appRouter.canPop()) {
        appRouter.pop();
      } else {
        appRouter.go(MainShellScreen.path);
      }
    } catch (_) {
      // Last resort: a direct Home navigation can't be worse than the
      // dead-end the user is already stranded on.
      try {
        appRouter.go(MainShellScreen.path);
      } catch (_) {/* nothing more we can safely do */}
    }
  }

  @override
  Widget build(BuildContext context) {
    const fg = AymaColors.darkFg;
    const muted = AymaColors.darkFgMute;
    return GestureDetector(
      onTap: _recover,
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
