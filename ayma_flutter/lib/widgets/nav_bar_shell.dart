import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../services/ayma_session.dart';
import '../services/tab_request.dart';
import 'ayma_tab_bar.dart';

/// Wraps a pushed screen with the app's one persistent bottom nav bar
/// (founder ask: literally every screen, no exceptions — see `app_router.dart`
/// for which routes this wraps and which don't).
///
/// [MainShellScreen] itself renders the identical-looking [AymaTabBar] as its
/// own `Scaffold.bottomNavigationBar`, bound to its live tab state — this
/// widget is for every *other* route, so tapping a tab here has to leave the
/// current page and land back in the shell on that tab. Since routing in this
/// app is flat (no `ShellRoute` nesting), that's a real navigation
/// (`context.go(MainShellScreen.path)`), which tears down and rebuilds
/// [MainShellScreen] from scratch — [TabRequest] is the one-slot hand-off
/// that tells the fresh shell which tab to land on (see that file's doc).
/// None of the four tabs is ever "current" from out here, so the bar always
/// renders with nothing highlighted.
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
  const NavBarShell({super.key, required this.child});

  final Widget child;

  void _goTab(BuildContext context, int index) {
    TabRequest.instance.push(index);
    context.go(MainShellScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        // The bar itself (unlike [child], which always builds its own
        // `Scaffold`) has no `Material` ancestor of its own here — it's a
        // sibling of [child] in this Column, not a descendant of its
        // Scaffold — and `AymaTabBar`'s tabs are `InkWell`s, which throw
        // without one. `MaterialType.transparency` so it paints nothing of
        // its own over the bar's already-opaque `Container` background.
        Material(
          type: MaterialType.transparency,
          child: ListenableBuilder(
            listenable: AymaSession.instance.voice,
            builder: (context, _) => AymaTabBar(
              index: -1,
              voiceActive: AymaSession.instance.voice.isActive,
              onSelected: (i) => _goTab(context, i),
            ),
          ),
        ),
      ],
    );
  }
}
