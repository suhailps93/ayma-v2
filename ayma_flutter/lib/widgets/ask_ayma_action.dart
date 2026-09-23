import 'package:flutter/material.dart';

import 'ayma_orb.dart';

/// The one, app-wide visual treatment for an "Ask Ayma" action wherever it
/// shows up in a screen's header — the Web-research report, someone else's
/// public profile, …: the Ayma logo mark (a small idle [AymaOrb], the same
/// mark used for the app's tab icon and its other "this is Ayma" moments)
/// followed by a label, one consistent size/spacing/color in both themes
/// (picked up from the app's [TextButtonThemeData], not hand-rolled here).
///
/// Founder feedback, from a screenshot comparing the Web-research report's
/// action against the public profile screen's: every one of these had grown
/// its own one-off icon/size/spacing and should instead "look the same —
/// just the Ayma logo with Ask Ayma text." This widget is that single
/// definition; every screen with an Ask-Ayma-style header action should use
/// it instead of building its own button.
///
/// [label] defaults to "Ask Ayma" — the public profile screen's self-view
/// ("Edit with Ayma") is the one legitimate exception in *wording* (a
/// different action: editing your own profile, not asking about someone
/// else's), not in styling, so it still renders through this same widget
/// with the same icon/size/spacing.
///
/// The orb renders as a single frozen frame, not [AymaOrb]'s usual
/// continuous drift: forced locally via `MediaQuery.disableAnimations`,
/// the same reduced-motion path the orb already paints through (see
/// `AymaOrbPainter.staticDetail`, which exists specifically to compensate
/// for a frozen frame). A permanently-visible 16px button icon reads better
/// as a stable mark than a perpetually-morphing blob — and, just as
/// importantly, an always-animating icon never lets `AnimationController`s
/// settle, which would hang `pumpAndSettle` in every widget test that
/// mounts a screen using this button.
class AskAymaAction extends StatelessWidget {
  const AskAymaAction({
    super.key,
    required this.onPressed,
    this.label = 'Ask Ayma',
  });

  /// Null disables the button (matches [TextButton.icon]'s own convention).
  final VoidCallback? onPressed;

  final String label;

  static const _orbSize = 16.0;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: const AymaOrb(size: _orbSize, state: AymaOrbState.idle),
      ),
      label: Text(label),
    );
  }
}
