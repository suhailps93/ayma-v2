import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../screens/voice_call_screen.dart';
import '../services/ayma_session.dart';
import '../services/tab_request.dart';
import 'ask_ayma_overlay.dart';
import 'ayma_chat_modal.dart';
import 'ayma_tab_bar.dart';
import 'staging_banner.dart';

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
    this.showStagingBanner,
  });

  final Widget child;

  /// True only for the Notifications route, so its own bar's Notifications
  /// tab is inert (see [AymaTabBar.notificationsActive]).
  final bool notificationsActive;

  /// Optional override for the staging ribbon. When null, defaults to
  /// [Env.isStaging].
  final bool? showStagingBanner;

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
  /// wired to this same method — see [_navBar]) grows the popup to full
  /// screen in place instead of stacking a second one.
  ///
  /// Any other tab while the popup is open closes it first: `_goTab`'s
  /// `context.go` replaces this route but would leave the imperatively-pushed
  /// popup stranded on top (it sits outside go_router's page stack), and
  /// navigating before its pop has completed tears the transition down
  /// mid-flight.
  Future<void> _onTabTap(BuildContext context, int i) async {
    if (i == 0) {
      if (isPageContextAymaPopupOpen) {
        pageContextAymaPopupSheet.expand();
      } else {
        showPageContextAymaPopup(context, navBarBuilder: _navBar);
      }
      return;
    }
    if (isPageContextAymaPopupOpen) {
      Navigator.of(context).pop();
      await pendingPageContextAymaPopup;
      if (!context.mounted) return;
    }
    _goTab(context, i);
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
  /// renders behaves identically to this one, including a tap on it
  /// expanding the popup rather than opening a second one. That copy
  /// highlights the orb while the popup is expanded to full screen.
  Widget _navBar(BuildContext context) {
    final expanded =
        AymaChatSheetController.maybeOf(context)?.isExpanded ?? false;
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: AymaSession.instance.voice,
        builder: (context, _) => AymaTabBar(
          index: expanded ? 0 : -1,
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
    // While the on-screen keyboard is up it covers the bar's spot anyway.
    // Keeping the bar in this Column would also shrink [child] by the bar's
    // height on top of the keyboard inset its own `Scaffold` already
    // applies, leaving a dead gap above the keyboard and, in a short window
    // (landscape, split-screen), squeezing the page until it overflows.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return StagingBanner(
      enabled: showStagingBanner,
      child: Column(
        children: [
          Expanded(child: child),
          if (!keyboardOpen) _navBar(context),
        ],
      ),
    );
  }
}
