import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../screens/voice_call_screen.dart';
import '../services/ayma_session.dart';
import '../services/tab_request.dart';
import 'ask_ayma_overlay.dart';
import 'ayma_tab_bar.dart';

/// Wraps a pushed screen with the app's one persistent bottom nav bar
/// (founder ask: literally every screen, no exceptions — see `app_router.dart`
/// for which routes this wraps and which don't).
///
/// [MainShellScreen] itself renders the identical-looking [AymaTabBar] as its
/// own `Scaffold.bottomNavigationBar`, bound to its live tab state — this
/// widget is for every *other* route, so tapping Explore/Messages/Profile
/// here has to leave the current page and land back in the shell on that
/// tab. Since routing in this app is flat (no `ShellRoute` nesting), that's a
/// real navigation (`context.go(MainShellScreen.path)`), which tears down and
/// rebuilds [MainShellScreen] from scratch — [TabRequest] is the one-slot
/// hand-off that tells the fresh shell which tab to land on (see that file's
/// doc). None of the four tabs is ever "current" from out here, so the bar
/// always renders with nothing highlighted.
///
/// The Ayma orb is the one exception to that navigate-back-to-the-shell rule
/// (see [_onTabTap]): since none of these wrapped screens IS the Ayma tab,
/// tapping it here always opens the scoped page-context popup
/// (`showPageContextAymaPopup`) instead of a [TabRequest] navigation —
/// founder ask: from a DM thread, the Story editor, a report screen, etc.,
/// the orb should behave "like the story edit" popup, not jump away to the
/// main chat tab.
///
/// Deliberately wraps [child] *inside* the routed page (each call site is a
/// `GoRoute.builder` return value), not as a global overlay sibling of the
/// whole `Router` — that keeps this bar part of the same page in the app's
/// single `Navigator`/`Overlay` stack as the screen it wraps, so a
/// `showModalBottomSheet`/`showDialog` opened from anywhere in [child] (the
/// Story editor's menus, "Chat about it", the birthdate picker, …) still
/// correctly covers this bar too, the same way one already correctly covers
/// [MainShellScreen]'s own — not left floating, bright and tappable, right
/// below an open sheet.
class NavBarShell extends StatelessWidget {
  const NavBarShell({
    super.key,
    required this.child,
    this.notificationsActive = false,
  });

  final Widget child;

  /// True only for the Notifications route, so its own bar's Notifications
  /// tab is inert (see [AymaTabBar.notificationsActive]).
  final bool notificationsActive;

  void _goTab(BuildContext context, int index) {
    TabRequest.instance.request(index);
    context.go(MainShellScreen.path);
  }

  /// [AymaTabBar]'s `onSelected` here. None of the four tabs is ever
  /// "current" from out here (see the class doc), so unlike
  /// [MainShellScreen]'s own copy of this dispatch the orb has no "already
  /// there" case to check for — every screen wrapped by this shell gets the
  /// scoped page-context popup (founder ask: "like the story edit", not a
  /// navigation back to the main tab) instead of [_goTab]. A second orb tap
  /// while that popup is already open (its own on-top copy of this same bar,
  /// wired to this same method — see [_navBar]) dismisses it and heads to the
  /// real Ayma tab instead of stacking a second popup (founder ask, round 2).
  Future<void> _onTabTap(BuildContext context, int i) async {
    if (i == 0) {
      if (isPageContextAymaPopupOpen) {
        // `_goTab`'s `context.go` replaces this whole route, popup included
        // — but it doesn't pop the popup *for* us (an imperatively-pushed
        // route like this modal sheet sits outside go_router's own page
        // stack, so a declarative navigation alone leaves it stranded on
        // top, still showing). Pop it explicitly, then wait for that pop's
        // own dismiss transition to actually finish (`pendingPageContextAymaPopup`)
        // before navigating — doing both in the same frame instead tears the
        // transition down mid-flight ("animation still running after the
        // widget tree was disposed").
        Navigator.of(context).pop();
        await pendingPageContextAymaPopup;
        if (context.mounted) _goTab(context, 0);
      } else {
        showPageContextAymaPopup(
          context,
          navBarBuilder: _navBar,
          // The popup header's expand button re-enters this very method as
          // a second orb tap — the "already open" branch above dismisses
          // the popup and heads to the real Ayma tab, chip dropped.
          onExpandRequested: () => _onTabTap(context, 0),
        );
      }
    } else {
      _goTab(context, i);
    }
  }

  /// The bar itself (unlike [child], which always builds its own `Scaffold`)
  /// has no `Material` ancestor of its own here — it's a sibling of [child]
  /// in this Column, not a descendant of its Scaffold — and `AymaTabBar`'s
  /// tabs are `InkWell`s, which throw without one. `MaterialType.transparency`
  /// so it paints nothing of its own over the bar's already-opaque `Container`
  /// background.
  ///
  /// Reused verbatim (same `onSelected`) as [showPageContextAymaPopup]'s
  /// `navBarBuilder` — see [_onTabTap]'s doc — so the on-top copy the popup
  /// renders behaves identically to this one, including a tap on it deciding
  /// to dismiss the popup and navigate rather than opening a second one.
  Widget _navBar(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: AymaSession.instance.voice,
        builder: (context, _) => AymaTabBar(
          index: -1,
          notificationsActive: notificationsActive,
          voice: AymaSession.instance.voice,
          onSelected: (i) => _onTabTap(context, i),
          onOrbLongPress: () =>
              toggleVoiceCall(context, AymaSession.instance.voice),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        _navBar(context),
      ],
    );
  }
}
