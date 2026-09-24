import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../theme.dart';
import 'ayma_orb.dart';
import 'notification_bell.dart';

/// The bottom tab bar in the Ayma design language: a translucent bar with a
/// top hairline and four plain icons — no text labels, so whatever's above it
/// gets the extra breathing room. The Ayma orb sits in the visual middle
/// (founder ask: "move the Ayma logo to the middle") — see [_visualOrder] —
/// even though its underlying tab index is still `0`, same as before; only
/// the on-screen position moved, not which tab each icon switches to. Each
/// tab keeps its name as a [Tooltip] (long-press / screen-reader accessible)
/// even though it's no longer painted on screen.
///
/// Shared by [MainShellScreen] (the real 4-tab shell, where it lives as the
/// `Scaffold`'s `bottomNavigationBar`) and any screen pushed on top of the
/// shell that should still show a persistent, functional bar rather than none
/// at all (founder ask: "make sure the bottom nav bar is visible in all
/// pages" — see `PublicProfileScreen`, the screen he screenshotted). Extracted
/// so there's exactly one bottom-bar implementation, not a near-identical
/// second one per caller.
///
/// [index] is which tab currently reads as selected; pass `-1` from a caller
/// that isn't actually one of the four tabs itself (a pushed detail screen
/// with no single "current tab" of its own) so no icon falsely highlights.
///
/// A 5th entry — the notification bell, with its live unread-count badge —
/// sits after Profile. Unlike the four real tabs it never highlights as
/// "selected" and doesn't switch [MainShellScreen]'s `IndexedStack`: it
/// always pushes [NotificationCenterScreen] instead, since Notifications
/// isn't a persistent tab body.
///
/// The Ayma orb reads noticeably larger than the other icons (22 -> 32,
/// `_orbBoxSize` below) — this bar is the app's *sole* entry point into Ayma
/// chat now that the standalone floating launcher is gone (see
/// `MainShellScreen`'s own doc), so it should read as the row's anchor. The
/// outer `Padding`'s `vertical: 10` -> `6` absorbs the extra 8px so
/// [contentHeight] — and every caller relying on it for clearance — stays
/// unchanged.
///
/// [onSelected] fires with the tapped tab's real index for all four tabs,
/// orb included, the same as always — this widget itself makes no
/// distinction for the orb. What tapping it actually *does* differs by host:
/// [MainShellScreen] passes its live tab index (so it can tell "already on
/// the Ayma tab" apart from "somewhere else" and only switch the
/// `IndexedStack` in the former case); every other host passes `-1` (never
/// "on" the Ayma tab) and opens the scoped page-context popup instead of
/// navigating to the tab — see `MainShellScreen._onTabTap`,
/// `NavBarShell._goTab`, and `PublicProfileScreen._goToTab`.
class AymaTabBar extends StatelessWidget {
  const AymaTabBar({
    super.key,
    required this.index,
    required this.voiceActive,
    required this.onSelected,
  });

  final int index;
  final bool voiceActive;
  final ValueChanged<int> onSelected;

  /// This bar's own real on-screen height, *excluding* whatever the device's
  /// bottom safe-area inset adds (the bar's `SafeArea(top: false)` — default
  /// `bottom: true` — pads that in separately at paint time): the outer
  /// `Padding`'s `vertical: 6` (12 total) plus one `_AymaTab`'s content
  /// height (`Padding.all(12)` = 24, around the taller of the two icon boxes
  /// — the orb's own 32px one, see `_orbBoxSize` — = 56). A caller that needs
  /// to float something a fixed gap above this bar — this screen isn't the
  /// only one; any pushed-on-top-of-the-shell screen with its own floating
  /// chrome above a persistent tab bar has the same problem — adds
  /// `MediaQuery.paddingOf(context).bottom` itself rather than guessing a
  /// single fixed number that only happens to work on one device.
  static const contentHeight = 68.0;

  /// The orb tab's own icon box — bigger than [_iconBoxSize] to fit the
  /// larger orb (see the class doc); the other three tabs keep their
  /// original box.
  static const _orbBoxSize = 32.0;
  static const _iconBoxSize = 24.0;

  static const _labels = ['Ayma', 'Explore', 'Messages', 'Profile'];
  static const _icons = [
    null,
    (Icons.search_rounded, Icons.search_rounded),
    (Icons.mail_outline_rounded, Icons.mail_rounded),
    (Icons.person_outline_rounded, Icons.person_rounded),
  ];

  /// Visual left-to-right order of the four real tabs' indices into
  /// [_labels]/[_icons] — Explore, Messages, Ayma (middle), Profile. Each
  /// entry's `onSelected(i)` callback still fires with its real tab index
  /// (`_labels[i]`/its position in [MainShellScreen]'s `IndexedStack`), only
  /// the on-screen position changed.
  static const _visualOrder = [1, 2, 0, 3];

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
              for (final i in _visualOrder)
                _AymaTab(
                  label: _labels[i],
                  onTap: () => onSelected(i),
                  boxSize: i == 0 ? _orbBoxSize : _iconBoxSize,
                  icon: i == 0
                      ? AymaOrb(
                          size: _orbBoxSize,
                          active: voiceActive,
                          voiceLive: voiceActive,
                        )
                      : Icon(
                          (index == i ? _icons[i]!.$2 : _icons[i]!.$1),
                          size: 22,
                          color: index == i ? ac.fg : ac.fgMute,
                        ),
                ),
              _AymaTab(
                label: 'Notifications',
                onTap: () => context.push(NotificationCenterScreen.path),
                boxSize: _iconBoxSize,
                icon: NotificationBellButton(compact: true, iconColor: ac.fgMute),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AymaTab extends StatelessWidget {
  const _AymaTab({
    required this.label,
    required this.onTap,
    required this.icon,
    this.boxSize = AymaTabBar._iconBoxSize,
  });

  final String label;
  final VoidCallback onTap;
  final Widget icon;
  final double boxSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            height: boxSize,
            width: boxSize,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}
