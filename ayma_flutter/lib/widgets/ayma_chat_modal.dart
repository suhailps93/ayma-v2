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
/// Wraps [builder]'s content in its own [ScaffoldMessenger] scope: the
/// embedded content is always a full [ChatScreen], which renders its own
/// `Scaffold` — without a fresh messenger here, a `SnackBar` it shows (a
/// declined second voice call, a send failure) would render into *both* that
/// `Scaffold` and whichever `Scaffold` sits underneath this modal (the
/// screen it opened over), since both would otherwise share the one
/// `ScaffoldMessenger` `MaterialApp` provides — a real, if easy to miss,
/// Flutter gotcha with any nested `Scaffold`, not something cosmetic.
Future<void> showAymaChatModal(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => _AymaChatModalSheet(builder: builder),
  );
}

class _AymaChatModalSheet extends StatefulWidget {
  const _AymaChatModalSheet({required this.builder});

  final WidgetBuilder builder;

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
    // A fresh `ScaffoldMessenger` scope for everything below — see
    // `showAymaChatModal`'s doc for why this matters (the embedded
    // `ChatScreen`'s own `Scaffold` would otherwise double up any `SnackBar`
    // with whichever `Scaffold` sits under this modal).
    return ScaffoldMessenger(
      child: DraggableScrollableSheet(
        controller: _sheetController,
        expand: false,
        initialChildSize: sizes[1],
        minChildSize: sizes[0],
        maxChildSize: sizes[2],
        snap: true,
        snapSizes: sizes,
        builder: (context, scrollController) => DecoratedBox(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(
              top: BorderSide(color: ac.lineSoft, width: 0.5),
              left: BorderSide(color: ac.lineSoft, width: 0.5),
              right: BorderSide(color: ac.lineSoft, width: 0.5),
            ),
          ),
          child: Column(
            children: [
              // The drag-handle dock — a real, if content-less, Scrollable
              // wired to the sheet's own `scrollController`, so a drag
              // starting exactly here resizes the sheet through
              // `DraggableScrollableSheet`'s completely standard mechanism.
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
                // Forces bouncy (iOS-style) overscroll physics for the chat's
                // own list even on Android, whose platform-default clamping
                // physics silently drops position updates once a scroll hits
                // its boundary — no `ScrollUpdateNotification` at all beyond
                // that point, which would starve `_bridgeChatDrag` of the very
                // deltas it needs once the user keeps dragging past the edge.
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
        ),
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
