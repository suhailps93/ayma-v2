import 'package:ayma_flutter/widgets/ayma_orb.dart';

/// The launcher-icon render pose, shared by the offline generator
/// (`tool/generate_app_icon_test.dart`) and its regression test
/// (`test/launcher_icon_pose_test.dart`) so the test guards the exact frame
/// that ships — a drift in either file breaks the other at compile time.
abstract final class IconRenderPose {
  /// The flutter cycle's symmetric slightly-closed instant: both wings near
  /// -0.09 rad (joint -0.0916, symmetric to ~2e-4 at amplitude 1) — the
  /// raised bright heart/V of the live speaking orb (FOUNDER_TARGET.png).
  /// Positive rotation opens a wing outward+down, so the joint-maximum-OPEN
  /// frame reads as a wide flat U: the resting orb (Task 2).
  static const double t = 7.1915;

  static const double amplitude = 1;
  static const AymaOrbState fromState = AymaOrbState.speaking;
  static const AymaOrbState toState = AymaOrbState.speaking;
  static const double transitionT = 1;
  static const bool showGlow = true;
  static const bool voiceLive = true;

  /// The Task-1 joint-maximum-open frame (t=9.9642, both wings within ~4% of
  /// the 0.16 soft-open ceiling): the regression test's negative control for
  /// the flat/resting misread. Same state/amplitude/glow as the icon pose —
  /// only the flutter phase differs.
  static const double flatControlT = 9.9642;
}
