/// A one-slot hand-off asking [MainShellScreen] which tab to land on the next
/// time it mounts — the same "push a value, the target screen consumes it on
/// arrival" shape as [ChatInbox] (`chat_inbox.dart`), just for tab selection
/// instead of an Ayma kickoff.
///
/// Needed because routing in this app is flat (no `ShellRoute` nesting — see
/// `app_router.dart`): navigating to [MainShellScreen] from any other pushed
/// route (`context.go(MainShellScreen.path)`) tears down and rebuilds it from
/// scratch, so there is no live shell `State` to call a tab-select method on
/// directly. The persistent bottom nav bar (`persistent_nav_bar.dart`) pushes
/// the tab it was tapped on for here immediately before navigating; the fresh
/// [MainShellScreen] reads it back in `initState`.
class TabRequest {
  TabRequest._();
  static final TabRequest instance = TabRequest._();

  int? _pending;

  void push(int index) => _pending = index;

  /// Take and clear the pending tab index (null if none was requested).
  int? take() {
    final i = _pending;
    _pending = null;
    return i;
  }
}
