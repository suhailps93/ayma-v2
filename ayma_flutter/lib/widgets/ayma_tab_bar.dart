import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import 'ayma_orb.dart';
import 'messages_unread_icon.dart';
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
/// sits just before Profile (the far-right tab). Unlike the four real tabs it never highlights as
/// "selected" and doesn't switch [MainShellScreen]'s `IndexedStack`: it
/// always pushes [NotificationCenterScreen] instead, since Notifications
/// isn't a persistent tab body.
///
/// The Ayma orb reads noticeably larger than the other icons (22 -> 32 -> 64,
/// `_orbBoxSize` below — founder ask: "make the Ayma logo twice the size in
/// the navbar") — this bar is the app's *sole* entry point into Ayma chat now
/// that the standalone floating launcher is gone (see `MainShellScreen`'s own
/// doc), so it should read as the row's anchor. The orb tab's own smaller
/// vertical padding (`_orbVerticalPadding`) keeps the bigger orb from also
/// inflating the bar's height by as much as the raw size jump would suggest —
/// see [contentHeight]'s doc for the exact accounting, and update that
/// constant (every caller relying on it for clearance depends on it staying
/// accurate) if this sizing changes again.
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
///
/// Holding the orb for [holdDuration] (1s) instead fires [onOrbLongPress] —
/// every host wires it to start a voice call — with a medium haptic and a thin
/// ring filling around the orb as the cue. A hold that completes never also
/// counts as a tap; letting go (or dragging off) early is just a normal tap /
/// cancel.
class AymaTabBar extends StatelessWidget {
  const AymaTabBar({
    super.key,
    required this.index,
    required this.voice,
    required this.onSelected,
    this.onOrbLongPress,
    this.notificationsActive = false,
  });

  final int index;

  /// True when the screen hosting this bar IS the Notifications screen, so
  /// re-tapping the Notifications tab is a no-op instead of pushing a second
  /// copy of it. Same for the four real tabs: tapping the one already
  /// selected ([index]) does nothing rather than replaying a transition.
  final bool notificationsActive;

  /// The shared voice session, or null when no call is active/relevant to
  /// this caller (every real caller passes `AymaSession.instance.voice` —
  /// see the class doc). Drives the orb tab's [AymaOrbState], amplitude
  /// reactivity and `voiceLive` glow (founder ask: "the same animation
  /// should happen in the nav bar logo too") the same way
  /// `VoiceCallScreen`/`SignInScreen` already map `phase`/`agentSpeaking` to
  /// the orb — see [_orbState]/[_orbAmplitude] below. A null (or fully idle)
  /// controller renders exactly like the old plain `active: false` case.
  final VoiceSessionController? voice;
  final ValueChanged<int> onSelected;

  /// Fired when the orb tab is held for [holdDuration]; null disables the
  /// hold (a plain tap still works).
  final VoidCallback? onOrbLongPress;

  static const holdDuration = Duration(seconds: 1);

  /// Same `phase`/`agentSpeaking` -> [AymaOrbState] mapping
  /// `VoiceCallScreen`/`SignInScreen` use, so the nav-bar orb genuinely
  /// reflects the live call instead of being pinned to `listening`.
  AymaOrbState get _orbState {
    final v = voice;
    if (v == null) return AymaOrbState.idle;
    return switch (v.phase) {
      VoiceSessionPhase.connecting ||
      VoiceSessionPhase.waking => AymaOrbState.thinking,
      VoiceSessionPhase.live =>
        v.agentSpeaking ? AymaOrbState.speaking : AymaOrbState.listening,
      _ => AymaOrbState.idle,
    };
  }

  /// Ayma's own output level while she's talking, the user's mic level
  /// otherwise — same choice `VoiceCallScreen`/`SignInScreen` make. Null
  /// (not 0) when there's no controller, so [AymaOrb] falls back to its
  /// static `amplitude: 0` default rather than merging a listenable that
  /// never fires.
  ValueListenable<double>? get _orbAmplitude {
    final v = voice;
    if (v == null) return null;
    return v.agentSpeaking ? v.aymaLevel : v.micLevel;
  }

  /// This bar's own real on-screen height, *excluding* whatever the device's
  /// bottom safe-area inset adds (the bar's `SafeArea(top: false)` — default
  /// `bottom: true` — pads that in separately at paint time): the outer
  /// `Padding`'s `vertical: 6` (12 total) plus the orb tab's own content
  /// height (its [_orbVerticalPadding] top+bottom, around [_orbBoxSize] — the
  /// tallest of the row's children, so it — not the other tabs' 24px-icon/
  /// 12px-padding box — sets the bar's height). A caller that needs to float
  /// something a fixed gap above this bar — this screen isn't the only one;
  /// any pushed-on-top-of-the-shell screen with its own floating chrome above
  /// a persistent tab bar has the same problem — adds
  /// `MediaQuery.paddingOf(context).bottom` itself rather than guessing a
  /// single fixed number that only happens to work on one device.
  ///
  /// Founder ask: "make the Ayma logo twice the size" (32 -> 64, see
  /// [_orbBoxSize]). Doubling the box while keeping the other tabs' 12px
  /// `Padding.all` would have grown this bar by 32px (56 -> 88) just from one
  /// tab's padding — instead the orb tab gets its own, smaller vertical
  /// padding ([_orbVerticalPadding]: 12 -> 4) so the bar grows only enough to
  /// fit the bigger orb itself (56 -> 72), not the padding around it; the
  /// other four icons' own box/padding, and the bar's horizontal rhythm
  /// (`spaceAround`, unaffected by a taller row), are untouched.
  static const contentHeight = 84.0;

  /// [contentHeight] in a short window (split-screen, freeform resize,
  /// landscape phone — see [isCompact]): the orb shrinks to
  /// [_compactOrbBoxSize] and the paddings tighten (4 + 4 + 40 + 4 + 4), so
  /// the bar never eats a third of a 300px window.
  static const compactContentHeight = 56.0;

  /// Below this window height the bar renders compact.
  static const compactBelowHeight = 480.0;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).height < compactBelowHeight;

  /// The bar's full on-screen height in [context]'s window, bottom safe-area
  /// inset included — what a caller floating chrome above the bar reserves.
  static double heightFor(BuildContext context) =>
      (isCompact(context) ? compactContentHeight : contentHeight) +
      MediaQuery.paddingOf(context).bottom;

  static const _compactOrbBoxSize = 40.0;

  /// The orb tab's own icon box — bigger than [_iconBoxSize] to fit the
  /// larger orb (see the class doc); the other three tabs keep their
  /// original box.
  static const _orbBoxSize = 64.0;
  static const _iconBoxSize = 24.0;

  /// Vertical padding around the orb's own box (see [contentHeight]'s doc) —
  /// smaller than the other tabs' shared 12px `Padding.all` so doubling
  /// [_orbBoxSize] doesn't also double the padding around it.
  static const _orbVerticalPadding = 4.0;

  static const _labels = ['Ayma', 'Explore', 'Messages', 'Profile'];
  static const _icons = [
    null,
    (Icons.search_rounded, Icons.search_rounded),
    (Icons.mail_outline_rounded, Icons.mail_rounded),
    (Icons.person_outline_rounded, Icons.person_rounded),
  ];

  /// Visual left-to-right order of the four real tabs' indices into
  /// [_labels]/[_icons] — Explore, Messages, Ayma (middle), [Notifications], Profile. Each
  /// entry's `onSelected(i)` callback still fires with its real tab index
  /// (`_labels[i]`/its position in [MainShellScreen]'s `IndexedStack`), only
  /// the on-screen position changed.
  static const _visualOrder = [1, 2, 0, 3];

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final compact = isCompact(context);
    final orbBox = compact ? _compactOrbBoxSize : _orbBoxSize;
    Widget tab(int i) => _AymaTab(
      label: _labels[i],
      onTap: () {
        if (i == index) return;
        onSelected(i);
      },
      onHold: i == 0 ? onOrbLongPress : null,
      boxSize: i == 0 ? orbBox : _iconBoxSize,
      padding: i == 0
          ? const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: _orbVerticalPadding,
            )
          : EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 8 : 12),
      icon: i == 0
          ? AymaOrb(
              size: orbBox,
              state: _orbState,
              amplitudeListenable: _orbAmplitude,
              voiceLive: voice?.isActive ?? false,
              // Scopes the user's "Wing flutter in nav bar"
              // setting to exactly these orbs — see
              // `OrbAnimationSettings`.
              navBarVariant: true,
            )
          : i == 2
          ? MessagesUnreadIcon(
              icon: index == i ? _icons[i]!.$2 : _icons[i]!.$1,
              color: index == i ? ac.fg : ac.fgMute,
            )
          : Icon(
              (index == i ? _icons[i]!.$2 : _icons[i]!.$1),
              size: 22,
              color: index == i ? ac.fg : ac.fgMute,
            ),
    );
    return Container(
      decoration: BoxDecoration(
        color: ac.bg,
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 4 : 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final i in _visualOrder.take(_visualOrder.length - 1))
                tab(i),
              _AymaTab(
                label: 'Notifications',
                onTap: () {
                  if (notificationsActive) return;
                  context.push(NotificationCenterScreen.path);
                },
                boxSize: _iconBoxSize,
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: compact ? 8 : 12,
                ),
                icon: NotificationBellButton(
                  compact: true,
                  iconColor: ac.fgMute,
                ),
              ),
              tab(_visualOrder.last),
            ],
          ),
        ),
      ),
    );
  }
}

class _AymaTab extends StatefulWidget {
  const _AymaTab({
    required this.label,
    required this.onTap,
    required this.icon,
    this.onHold,
    this.boxSize = AymaTabBar._iconBoxSize,
    this.padding = const EdgeInsets.all(12),
  });

  final String label;
  final VoidCallback onTap;
  final Widget icon;

  /// Fired after a [AymaTabBar.holdDuration] press; the release that follows
  /// is swallowed rather than also firing [onTap]. Null = no hold behavior.
  final VoidCallback? onHold;
  final double boxSize;

  /// Defaults to the original uniform 12px used by every non-orb tab; the
  /// orb tab passes its own smaller vertical padding so doubling its box
  /// doesn't also double the bar's height — see [AymaTabBar.contentHeight].
  final EdgeInsets padding;

  @override
  State<_AymaTab> createState() => _AymaTabState();
}

class _AymaTabState extends State<_AymaTab>
    with SingleTickerProviderStateMixin {
  // Drives both the ring and the 1s threshold: completing is the hold firing.
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: AymaTabBar.holdDuration,
  )..addStatusListener(_onHoldStatus);

  bool _held = false;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _onHoldStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _held = true;
    HapticFeedback.mediumImpact();
    widget.onHold?.call();
    _hold.reset();
  }

  void _onTapDown(TapDownDetails _) {
    _held = false;
    if (widget.onHold != null) _hold.forward(from: 0);
  }

  void _cancelHold() => _hold.reset();

  void _onTap() {
    _hold.reset();
    if (_held) {
      _held = false;
      return;
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final onHold = widget.onHold;
    return Tooltip(
      message: widget.label,
      // The default long-press trigger would win the gesture arena at 500ms
      // and cancel the tap, so the 1s hold could never complete.
      triggerMode: onHold == null ? null : TooltipTriggerMode.manual,
      child: Semantics(
        hint: onHold == null ? null : 'Hold 1s for voice',
        onLongPress: onHold,
        child: InkWell(
          onTap: _onTap,
          onTapDown: _onTapDown,
          onTapCancel: _cancelHold,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: widget.padding,
            child: SizedBox(
              height: widget.boxSize,
              width: widget.boxSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(child: widget.icon),
                  if (onHold != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _hold,
                          builder: (context, _) => _hold.value == 0
                              ? const SizedBox.shrink()
                              : CircularProgressIndicator(
                                  value: _hold.value,
                                  strokeWidth: 2,
                                  color: context.ac.fg,
                                  backgroundColor: Colors.transparent,
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
