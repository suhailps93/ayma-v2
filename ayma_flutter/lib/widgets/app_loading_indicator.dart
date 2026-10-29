import 'package:flutter/material.dart';

import '../theme.dart';

/// The one standard page/report loading indicator: a [CircularProgressIndicator]
/// tinted to the user's accent colour, centred. Used everywhere the app is
/// still loading a PAGE or a REPORT (Explore, the Appearance/Face/Body report
/// views, …) so every "content is loading" moment looks the same (founder:
/// "when loading a page don't show the Ayma logo; show the loading logo used in
/// Explore — use a standardized one everywhere").
///
/// The branded animated [AymaLogoLoader] is deliberately NOT used for page
/// loads any more — it's reserved for the voice wake/connect state (the chat
/// composer's connecting slot), where the "Ayma waking up" animation belongs.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({super.key, this.size = 36, this.strokeWidth = 3});

  /// Diameter of the spinner in logical pixels.
  final double size;

  /// Stroke width of the spinner arc.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: strokeWidth,
          // The user's chosen accent — the same source the rest of the app
          // reads (`context.ac`), so the loader matches the active theme.
          color: context.ac.accent,
        ),
      ),
    );
  }
}
