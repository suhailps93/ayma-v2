import 'package:flutter/foundation.dart';

/// A one-slot hand-off asking [MainShellScreen] to land on a specific tab the
/// next time it's shown — same shape as [ChatInbox]'s kickoff slot, but for
/// plain tab selection rather than an Ayma skill.
///
/// Used by screens pushed on top of the shell that still show their own
/// [AymaTabBar] (e.g. `PublicProfileScreen` — see its doc), so tapping a tab
/// icon there both returns to the shell (`context.go(MainShellScreen.path)`)
/// *and* selects that tab, instead of leaving the shell on whichever tab it
/// happened to be on before.
class TabRequest {
  TabRequest._();
  static final TabRequest instance = TabRequest._();

  final ValueNotifier<int?> pending = ValueNotifier<int?>(null);

  void request(int index) => pending.value = index;

  /// Consumed once; clears itself so a later rebuild doesn't reapply it.
  int? consume() {
    final v = pending.value;
    if (v != null) pending.value = null;
    return v;
  }
}
