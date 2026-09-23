import 'package:flutter/material.dart';

import '../theme.dart';
import 'ayma_orb.dart';

/// The app's one persistent bottom navigation bar, in the Ayma design
/// language: a translucent bar with a top hairline and four plain icons — no
/// text labels, so the chat composer (or whatever else sits above it) gets
/// the extra breathing room. The first tab carries the living orb instead of
/// an icon — enlarged relative to the other three (founder ask: it's now the
/// app's *sole* entry point into Ayma chat, the old floating top-right
/// launcher having been removed as redundant, so it should read as the clear
/// anchor of the bar without dominating it or upsetting the row's vertical
/// rhythm). Each tab keeps its name as a [Tooltip] (long-press /
/// screen-reader accessible) even though it's no longer painted on screen.
///
/// Two call sites render this identically:
/// - [MainShellScreen] itself, bound to its own live `_index`/`_selectTab`.
/// - Every other screen in the app, via `NavBarShell` (`nav_bar_shell.dart`,
///   wired per-route in `app_router.dart`), which always renders it with
///   nothing highlighted and navigates back into the shell (`TabRequest` +
///   `context.go`) on tap — see that file's doc for why.
class AymaTabBar extends StatelessWidget {
  const AymaTabBar({
    super.key,
    required this.index,
    required this.voiceActive,
    required this.onSelected,
  });

  /// Which tab reads as active — 0..3, or -1 when none of the four
  /// applies (a screen outside the shell entirely, e.g. Settings, a DM
  /// thread: the bar is still there to navigate *into* a tab, but none of
  /// them is "current").
  final int index;
  final bool voiceActive;
  final ValueChanged<int> onSelected;

  static const _labels = ['Ayma', 'Explore', 'Messages', 'Profile'];
  static const _icons = [
    null,
    (Icons.search_rounded, Icons.search_rounded),
    (Icons.mail_outline_rounded, Icons.mail_rounded),
    (Icons.person_outline_rounded, Icons.person_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      decoration: BoxDecoration(
        color: ac.bg,
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _labels.length; i++)
                _Tab(
                  label: _labels[i],
                  onTap: () => onSelected(i),
                  // The orb sits noticeably larger than the other three icons
                  // (22 -> 32): the bar's sole entry point into Ayma chat now
                  // that the floating launcher is gone, so it should read as
                  // the anchor of the row. The other icons' own tap targets
                  // are untouched, keeping the bar's height/rhythm stable.
                  icon: i == 0
                      ? AymaOrb(size: 32, active: voiceActive)
                      : Icon(
                          (index == i ? _icons[i]!.$2 : _icons[i]!.$1),
                          size: 22,
                          color: index == i ? ac.fg : ac.fgMute,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.onTap, required this.icon});

  final String label;
  final VoidCallback onTap;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(height: 32, width: 32, child: Center(child: icon)),
        ),
      ),
    );
  }
}
