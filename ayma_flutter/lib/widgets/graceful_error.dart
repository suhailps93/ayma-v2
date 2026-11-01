import 'package:flutter/material.dart';

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
        ],
      ),
    ),
  );
}
