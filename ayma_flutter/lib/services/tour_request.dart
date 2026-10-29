import 'package:flutter/foundation.dart';

/// A one-slot hand-off asking [MainShellScreen] to run the FULL feature tour
/// (§11.2a) the next time it's shown — the same shape as [TabRequest], but for
/// an on-demand replay rather than a tab switch.
///
/// The interactive coach-mark tour spotlights the shell's real UI (the chat
/// composer, the nav-bar orb and tabs), so it can only run while the shell is
/// the visible route. The Settings "How to use Ayma" entry and the Developer
/// panel preview therefore don't push a tour screen any more — they set this
/// request and `context.go(MainShellScreen.path)`. Flat routing rebuilds the
/// shell, whose gate consumes the request on its first frame and starts the
/// full walkthrough (ignoring the per-user seen-state, since this is a
/// deliberate replay).
class TourRequest {
  TourRequest._();
  static final TourRequest instance = TourRequest._();

  final ValueNotifier<bool> pending = ValueNotifier<bool>(false);

  /// Ask for a full replay on the next shell build.
  void requestFull() => pending.value = true;

  /// Consumed once; clears itself so a later rebuild doesn't reapply it.
  bool consume() {
    final v = pending.value;
    if (v) pending.value = false;
    return v;
  }
}
