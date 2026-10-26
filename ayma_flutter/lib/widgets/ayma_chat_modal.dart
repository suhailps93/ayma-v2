import 'package:flutter/material.dart';

import '../theme.dart';

/// The ONE dockable-chat-modal treatment used everywhere a conversation with
/// Ayma opens as an overlay rather than a full screen — the floating orb
/// launcher and every "tap to correct" affordance (Story, deep-dive,
/// Appearance) alike (see `ask_ayma_overlay.dart`'s `showAskAymaOverlay` and
/// `global_ayma_launcher.dart`). Docks over most of the screen (not a small
/// bottom sheet), drags open further or dismisses on a downward drag past its
/// minimum size, and dismisses on a tap outside it — all three are
/// `DraggableScrollableSheet` + `showModalBottomSheet`'s own standard,
/// built-in behavior, not anything bespoke here.
///
/// [builder] receives no scroll controller of its own on purpose: the
/// embedded content (always a [ChatScreen] in practice) gets its *own*,
/// independent `ScrollController` for its message list, and
/// [_bridgeChatDrag] below drives this sheet's size from that list's raw drag
/// deltas once it has nothing left to scroll toward — see that method's doc
/// for why sharing one `ScrollPosition` between the two doesn't work.
///
/// [persistentBottomBar] + [persistentBottomBarHeight] (evaluated against
/// the sheet's own, live window — so a split-screen resize or a fold/unfold
/// while the sheet is open keeps the reserved gap exact) are how
/// `showPageContextAymaPopup` keeps the app's persistent bottom nav bar
/// (`AymaTabBar`) visible and tappable while this sheet is open (founder
/// complaint: "Navbar don't show when chat popup is open" — the sheet used
/// to sit in a full-screen modal route that simply painted over the whole
/// screen, `AymaTabBar` included, no matter how short its own configured
/// sizes were). Left null by [showAskAymaOverlay]'s scoped correction turns
/// (Story/deep-dive/Appearance edits), which predate that nav-bar-everywhere
/// feature and have no bar of their own to reserve space for.
///
/// This is deliberately NOT "shrink the modal route's barrier so the bar
/// underneath peeks through": `showModalBottomSheet`'s `ModalBarrier` always
/// spans the *entire* screen for its tap-to-dismiss hit-testing regardless of
/// how short the visible sheet is, so a bar merely left uncovered by the
/// sheet would still have every tap swallowed by that barrier before it ever
/// reached the real bar underneath. Instead, [persistentBottomBar] renders a
/// **second copy** of the caller's own live bar (same index/voiceActive/
/// onSelected as whatever's underneath) as a sibling of the sheet in this
/// same modal route's content, painted *after* (so: on top of) the barrier —
/// visible at full opacity (the bar's own `Container` background is opaque)
/// and fully tappable, indistinguishable from the real one it sits exactly
/// on top of since both render identically.
Future<void> showAymaChatModal(
  BuildContext context, {
  required WidgetBuilder builder,
  WidgetBuilder? persistentBottomBar,
  double Function(BuildContext context)? persistentBottomBarHeight,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => _AymaChatModalSheet(
      builder: builder,
      persistentBottomBar: persistentBottomBar,
      persistentBottomBarHeight: persistentBottomBarHeight,
    ),
  );
}

class _AymaChatModalSheet extends StatefulWidget {
  const _AymaChatModalSheet({
    required this.builder,
    this.persistentBottomBar,
    this.persistentBottomBarHeight,
  });

  final WidgetBuilder builder;
  final WidgetBuilder? persistentBottomBar;
  final double Function(BuildContext context)? persistentBottomBarHeight;

  static const _sizes = [0.42, 0.62, 0.95];

  @override
  State<_AymaChatModalSheet> createState() => _AymaChatModalSheetState();
}

class _AymaChatModalSheetState extends State<_AymaChatModalSheet> {
  final _sheetController = DraggableScrollableController();

  /// True once [_bridgeChatDrag] has actually resized the sheet during the
  /// drag currently in progress — so its matching `ScrollEndNotification`
  /// knows to snap the sheet to the nearest configured size, the same way
  /// releasing a *native* handle-drag already does (`snap: true` below only
  /// covers drags the sheet's own scroll-controller mechanism handled).
  bool _bridging = false;

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  /// `DraggableScrollableSheet`'s built-in drag-to-resize only engages for a
  /// drag on a Scrollable built with *its own* `scrollController` — and only
  /// while that Scrollable's `pixels` are at `0` (see
  /// `_DraggableScrollableSheetScrollPosition.applyUserOffset` in the SDK).
  /// The drag-handle dock below satisfies that natively (it has nothing to
  /// scroll, so its `pixels` never leave `0`). The embedded chat's own
  /// message list can't: a live conversation rests scrolled to its *newest*
  /// message, i.e. `pixels` at `maxScrollExtent`, not `0` — so a drag
  /// starting there would, through the SDK's own mechanism alone, only ever
  /// scroll the list, never resize the sheet, no matter how the
  /// `scrollController` is wired.
  ///
  /// Once the list has nothing left to scroll toward in the drag's direction
  /// (`extentAfter <= 0` dragging up — the common case, since the chat
  /// already rests there; `extentBefore <= 0` dragging down), further
  /// movement grows/shrinks the sheet instead — expand-first over the chat,
  /// exactly like the native handle already does, per the SDK's own
  /// documented intent ("as long as the builder creates a widget which uses
  /// the provided ScrollController").
  bool _bridgeChatDrag(ScrollNotification n) {
    if (n is ScrollEndNotification && n.dragDetails != null) {
      final wasBridging = _bridging;
      _bridging = false;
      if (wasBridging && _sheetController.isAttached) {
        final nearest = _AymaChatModalSheet._sizes.reduce(
          (a, b) =>
              (a - _sheetController.size).abs() <=
                  (b - _sheetController.size).abs()
              ? a
              : b,
        );
        _sheetController.animateTo(
          nearest,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      return false;
    }
    if (n is! ScrollUpdateNotification ||
        n.dragDetails == null ||
        !_sheetController.isAttached) {
      return false;
    }
    final delta = n.dragDetails!.primaryDelta ?? 0;
    if (delta < 0 && n.metrics.extentAfter <= 0) {
      _bridging = true;
      _sheetController.jumpTo(
        (_sheetController.size + _sheetController.pixelsToSize(-delta)).clamp(
          0.0,
          1.0,
        ),
      );
    } else if (delta > 0 && n.metrics.extentBefore <= 0) {
      _bridging = true;
      _sheetController.jumpTo(
        (_sheetController.size - _sheetController.pixelsToSize(delta)).clamp(
          0.0,
          1.0,
        ),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final sizes = _AymaChatModalSheet._sizes;
    // `showModalBottomSheet` never insets its content for the keyboard on its
    // own (there's no `viewInsets` handling anywhere in the framework's
    // `_ModalBottomSheetRoute` — confirmed against the SDK source) — every
    // caller has to do it themselves. Without this, the sheet's
    // sizes (`_sizes` above) are fractions of the *full, un-reduced* screen
    // height and its box stays bottom-anchored at the screen's physical
    // bottom regardless of the keyboard, so the embedded [ChatScreen]'s
    // composer — the last thing in its `Column`, right at that bottom edge —
    // ends up sitting behind the keyboard instead of just above it.
    //
    // `MediaQuery.removeViewInsets` below then strips the same inset back out
    // for everything under this `Padding`: the embedded [ChatScreen] renders
    // its own `Scaffold` (`resizeToAvoidBottomInset` defaults to true there),
    // which would otherwise try to compensate for the very same keyboard a
    // *second* time — shifting its composer up by the keyboard's height
    // again, on top of the shift this `Padding` already gives the whole
    // sheet, leaving a pointless keyboard-height gap of dead space above it.
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final bar = widget.persistentBottomBar;
    // Evaluated live, so the reserved gap follows the window (the bar goes
    // compact in a short split-screen window, see `AymaTabBar.heightFor`).
    final barHeight = bar == null
        ? 0.0
        : (widget.persistentBottomBarHeight?.call(context) ?? 0.0);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Stack(
          // Bottom-anchor the sheet INSIDE this Stack — this is what
          // actually docks it. When [persistentBottomBar] is set, the
          // `Align` child below expands to the full route height (an
          // `Align` with no size factor fills bounded constraints), so the
          // Stack itself becomes full-height and the modal route's own
          // bottom-anchoring of it is a no-op; the sheet child, being
          // SHORTER than the Stack (its fraction of the height plus the
          // reserved bar gap), is then placed by the Stack's `alignment` —
          // whose default is topStart, which pinned the whole sheet to the
          // TOP of the screen with the underlying page showing through
          // below it (founder, 4x: "Pop up chat clearly not docked at the
          // bottom"). Every prior widget test missed it because none
          // asserted which edge the sheet hugs — see
          // `ayma_chat_modal_test.dart`'s flush-bottom assertions now.
          alignment: Alignment.bottomCenter,
          children: [
            // Reserving this gap below the sheet — rather than letting it
            // extend all the way to the screen's own bottom edge, as it did
            // before [persistentBottomBar] existed — is what leaves room
            // for that bar to sit in, un-overlapped, below.
            Padding(
              padding: EdgeInsets.only(bottom: barHeight),
              // With a bar (or the keyboard) below it, the sheet no longer
              // reaches the screen's bottom edge, so the system inset is
              // the bar's to pad, not the sheet's: left in, the embedded
              // composer's own SafeArea would add it a second time.
              // (`context` here is above the `removeViewInsets` wrapping
              // this Stack, so the keyboard inset is stripped again too.)
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .removeViewInsets(removeBottom: true)
                    .removePadding(
                      removeBottom:
                          widget.persistentBottomBar != null ||
                          viewInsets.bottom > 0,
                    ),
                child: DraggableScrollableSheet(
                  controller: _sheetController,
                  expand: false,
                  initialChildSize: sizes[1],
                  minChildSize: sizes[0],
                  maxChildSize: sizes[2],
                  snap: true,
                  snapSizes: sizes,
                  builder: (context, scrollController) =>
                      _sheetContent(ac, scrollController),
                ),
              ),
            ),
            if (bar != null)
              Align(
                alignment: Alignment.bottomCenter,
                // Keyed so tests can address this on-top copy
                // specifically (`find.descendant(of: find.byKey(...))`) —
                // the real bar it sits exactly on top of is still mounted
                // underneath, so an unscoped `find.byTooltip('Ayma')`
                // while this is showing matches both.
                child: KeyedSubtree(
                  key: const ValueKey('aymaChatModalNavBar'),
                  child: Builder(builder: bar),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sheetContent(AymaTokens ac, ScrollController scrollController) {
    return DecoratedBox(
      // The sheet's visible box — keyed so tests can measure its actual
      // rendered edges (bottom flush with the reserved bar area / route
      // bottom), not just its size. See the anchoring note on the Stack in
      // [build].
      key: const ValueKey('aymaChatModalSheetBox'),
      decoration: BoxDecoration(
                color: ac.bg,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
                border: Border(
                  top: BorderSide(color: ac.lineSoft, width: 0.5),
                  left: BorderSide(color: ac.lineSoft, width: 0.5),
                  right: BorderSide(color: ac.lineSoft, width: 0.5),
                ),
              ),
              child: Column(
                children: [
                  // The drag-handle dock — a real, if content-less,
                  // Scrollable wired to the sheet's own `scrollController`,
                  // so a drag starting exactly here resizes the sheet
                  // through `DraggableScrollableSheet`'s completely standard
                  // mechanism.
                  SizedBox(
                    key: const ValueKey('aymaChatModalHandle'),
                    height: 24,
                    child: ListView(
                      controller: scrollController,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: ac.lineSoft,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    // Forces bouncy (iOS-style) overscroll physics for the
                    // chat's own list even on Android, whose
                    // platform-default clamping physics silently drops
                    // position updates once a scroll hits its boundary — no
                    // `ScrollUpdateNotification` at all beyond that point,
                    // which would starve `_bridgeChatDrag` of the very
                    // deltas it needs once the user keeps dragging past the
                    // edge.
                    child: ScrollConfiguration(
                      behavior: const _BouncingScrollBehavior(),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _bridgeChatDrag,
                        child: Builder(builder: widget.builder),
                      ),
                    ),
                  ),
                ],
              ),
            );
  }
}

class _BouncingScrollBehavior extends MaterialScrollBehavior {
  const _BouncingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics();
}
