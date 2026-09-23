import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../theme.dart';
import 'ayma_orb.dart';
import 'notification_bell.dart';

/// The bottom tab bar in the Ayma design language: a translucent bar with a
/// top hairline and four plain icons — no text labels, so whatever's above it
/// gets the extra breathing room. The first tab carries the living orb
/// instead of an icon. Each tab keeps its name as a [Tooltip] (long-press /
/// screen-reader accessible) even though it's no longer painted on screen.
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
  /// `Padding`'s `vertical: 10` (20 total) plus one `_AymaTab`'s content
  /// height (`Padding.all(12)` around a 24px icon box = 48). A caller that
  /// needs to float something a fixed gap above this bar — this screen isn't
  /// the only one; any pushed-on-top-of-the-shell screen with its own
  /// floating chrome above a persistent tab bar has the same problem — adds
  /// `MediaQuery.paddingOf(context).bottom` itself rather than guessing a
  /// single fixed number that only happens to work on one device.
  static const contentHeight = 68.0;

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
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _labels.length; i++)
                _AymaTab(
                  label: _labels[i],
                  onTap: () => onSelected(i),
                  icon: i == 0
                      ? AymaOrb(size: 22, active: voiceActive)
                      : Icon(
                          (index == i ? _icons[i]!.$2 : _icons[i]!.$1),
                          size: 22,
                          color: index == i ? ac.fg : ac.fgMute,
                        ),
                ),
              _AymaTab(
                label: 'Notifications',
                onTap: () => context.push(NotificationCenterScreen.path),
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
  });

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
          child: SizedBox(height: 24, width: 24, child: Center(child: icon)),
        ),
      ),
    );
  }
}
