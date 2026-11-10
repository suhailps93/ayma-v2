import 'package:flutter/material.dart';

import '../theme.dart';

/// The ONE dockable-chat-modal treatment used everywhere a conversation with
/// Ayma opens as an overlay — the nav-bar orb's page-context popup and every
/// "tap to correct" affordance (Story, deep-dive, Appearance) alike (see
/// `ask_ayma_overlay.dart`). Docks over most of the screen (not a small
/// bottom sheet), drags open further or dismisses on a downward drag past its
/// minimum size, and dismisses on a tap outside it — all three are
/// `DraggableScrollableSheet` + `showModalBottomSheet`'s own standard,
/// built-in behavior, not anything bespoke here.
///
/// **Full screen is this same sheet at its largest snap size** (founder ask:
/// expanding must look like the sheet itself growing, not a new page
/// arriving). [AymaChatSheetController.expand] (the header's expand button,
/// a second orb tap) animates the one surface from its docked rect up to
/// the whole screen above the nav bar — its top edge rising under the status
/// bar, its corner radius and drag pill easing to nothing — and
/// [AymaChatSheetController.collapse] (the collapse button, system back)
/// shrinks it back the same way; a drag on the handle or past the message
/// list's edge moves it continuously between the two. Because nothing is
/// ever re-mounted, the transcript, scroll offset, composer text, focus,
/// keyboard and live voice state all simply carry across. With reduced
/// motion on, the size change is instant and the content fades in instead.
/// There is NEVER a second chat surface, and the page behind only dims (the
/// modal barrier) — the sheet itself does not slide down at any point.
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
///
/// [persistentBottomBar] + [persistentBottomBarHeight] (evaluated against
/// the sheet's own, live window — so a split-screen resize or a fold/unfold
/// while the sheet is open keeps the reserved gap exact) are how
/// `showPageContextAymaPopup` keeps the app's persistent bottom nav bar
/// (`AymaTabBar`) visible and tappable while this sheet is open (founder
/// complaint: "Navbar don't show when chat popup is open" — the sheet used
/// to sit in a full-screen modal route that simply painted over the whole
/// screen, `AymaTabBar` included, no matter how short its own configured
/// sizes were). [showAskAymaOverlay]'s scoped correction turns resolve the
/// same copy from the nearest [AymaNavBarScope] (§ D13: ONE chat — the sheet
/// is a partial page of the main chat with the bar visible); routes with no
/// scope above them leave it null and open bar-less, as before.
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
///
/// [controller] lets code outside the sheet (an orb tap on the bar
/// underneath it) expand or collapse it; content inside reaches the same
/// controller through [AymaChatSheetController.maybeOf].
///
/// [allowExpand] gates the full-screen size entirely: with it false the
/// snap sizes stop at the docked size, so no drag, handle pull or
/// [AymaChatSheetController.expand] call can grow the sheet past docked
/// and the hosted content's expanded presentation is unreachable. The
/// nav-bar orb's page-context popup passes false (founder order,
/// 2026-11-07): its grown state was a full-screen history view that
/// mounted its message list at the oldest turn — last night's
/// conversation — while the real main chat showed the live one, so it
/// read as a stale duplicate page; that destination is deleted, and the
/// popup's expand affordance goes to the real main chat instead.
/// Scoped Ask-Ayma correction sheets keep the default: their full
/// screen is the correction conversation itself, not a duplicate.
///
/// `useSafeArea` is off so the expanded sheet can reach the very top of the
/// screen; the caller's status-bar inset is captured here instead and given
/// back to the content only as far as the sheet actually grows into it.
Future<void> showAymaChatModal(
  BuildContext context, {
  required WidgetBuilder builder,
  WidgetBuilder? persistentBottomBar,
  double Function(BuildContext context)? persistentBottomBarHeight,
  AymaChatSheetController? controller,
  bool allowExpand = true,
}) {
  final topInset = MediaQuery.paddingOf(context).top;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => _AymaChatModalSheet(
      builder: builder,
      persistentBottomBar: persistentBottomBar,
      persistentBottomBarHeight: persistentBottomBarHeight,
      controller: controller,
      topInset: topInset,
      allowExpand: allowExpand,
    ),
  );
}

/// Expands/collapses the open [showAymaChatModal] sheet and reports which
/// of the two it is in. [isExpanded] flips as the sheet's size crosses the
/// midpoint between its docked and full-screen sizes, so anything keyed off
/// it (the header's expand/collapse icon, the page-context chip, the nav
/// bar's highlighted orb, system back) changes mid-gesture, not with a
/// late jump after the motion ends.
class AymaChatSheetController extends ChangeNotifier {
  _AymaChatModalSheetState? _sheet;
  bool _expanded = false;

  bool get isExpanded => _expanded;

  /// Grows the open sheet to full screen. A no-op with no sheet open.
  void expand() => _sheet?._settleTo(_AymaChatModalSheet.fullSize);

  /// Shrinks the open sheet back to its docked size. A no-op with no sheet
  /// open.
  void collapse() => _sheet?._settleTo(_AymaChatModalSheet.dockedSize);

  void _setExpanded(bool value) {
    if (value == _expanded) return;
    _expanded = value;
    notifyListeners();
  }

  /// The controller of the sheet [context] sits in, or null outside one.
  /// [listen] registers a rebuild dependency on [isExpanded].
  static AymaChatSheetController? maybeOf(
    BuildContext context, {
    bool listen = true,
  }) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<_AymaChatSheetScope>()
        : context.getInheritedWidgetOfExactType<_AymaChatSheetScope>();
    return scope?.notifier;
  }
}

class _AymaChatSheetScope extends InheritedNotifier<AymaChatSheetController> {
  const _AymaChatSheetScope({
    required AymaChatSheetController controller,
    required super.child,
  }) : super(notifier: controller);
}

class _AymaChatModalSheet extends StatefulWidget {
  const _AymaChatModalSheet({
    required this.builder,
    required this.topInset,
    this.persistentBottomBar,
    this.persistentBottomBarHeight,
    this.controller,
    this.allowExpand = true,
  });

  final WidgetBuilder builder;
  final WidgetBuilder? persistentBottomBar;
  final double Function(BuildContext context)? persistentBottomBarHeight;
  final AymaChatSheetController? controller;
  final double topInset;
  final bool allowExpand;

  static const minSize = 0.42;
  static const dockedSize = 0.62;
  static const fullSize = 1.0;
  static const _sizes = [minSize, dockedSize, fullSize];

  /// [AymaChatSheetController.isExpanded] flips here, halfway between the
  /// docked and full sizes.
  static const _expandedAbove = (dockedSize + fullSize) / 2;

  static const _cornerRadius = 28.0;

  @override
  State<_AymaChatModalSheet> createState() => _AymaChatModalSheetState();
}

class _AymaChatModalSheetState extends State<_AymaChatModalSheet>
    with SingleTickerProviderStateMixin {
  final _sheetController = DraggableScrollableController();
  late final AymaChatSheetController _controller =
      widget.controller ?? AymaChatSheetController();

  /// The sizes this sheet may settle at — without [widget.allowExpand]
  /// the full-screen size is not among them, so no gesture or
  /// [AymaChatSheetController.expand] call can grow the sheet past
  /// docked.
  List<double> get _snapSizes => widget.allowExpand
      ? _AymaChatModalSheet._sizes
      : const [_AymaChatModalSheet.minSize, _AymaChatModalSheet.dockedSize];

  /// The sheet's live size (fraction of [_available]), fed by the sheet's
  /// own `DraggableScrollableNotification`s so only the chrome that depends
  /// on it (corner radius, status-bar inset, drag pill) repaints per frame,
  /// never the embedded chat.
  final _size = ValueNotifier<double>(_AymaChatModalSheet.dockedSize);

  /// The sheet's full-size height in pixels (its layout constraints).
  double _available = 0;

  /// Reduced-motion fallback: a size change is instant, and this fades the
  /// content back in so the jump still reads as one surface changing.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _controller._sheet = this;
  }

  /// True once [_bridgeChatDrag] has actually resized the sheet during the
  /// drag currently in progress — so its matching `ScrollEndNotification`
  /// knows to snap the sheet to the nearest configured size, the same way
  /// releasing a *native* handle-drag already does (`snap: true` below only
  /// covers drags the sheet's own scroll-controller mechanism handled).
  bool _bridging = false;

  @override
  void dispose() {
    if (identical(_controller._sheet, this)) _controller._sheet = null;
    if (widget.controller == null) {
      _controller.dispose();
    } else {
      // A shared controller outlives this sheet: reset it silently (its
      // only listener, this sheet's own scope, is going away with it).
      _controller._expanded = false;
    }
    _fade.dispose();
    _size.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  void _settleTo(double size) {
    if (!_sheetController.isAttached) return;
    // A sheet that may not expand settles at its largest allowed size
    // instead — expand() on it is a no-op, never an error.
    size = size.clamp(_snapSizes.first, _snapSizes.last);
    if (MediaQuery.disableAnimationsOf(context)) {
      _sheetController.jumpTo(size);
      _fade.forward(from: 0);
      return;
    }
    _sheetController.animateTo(
      size,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  bool _onSheetSize(DraggableScrollableNotification n) {
    _size.value = n.extent;
    _controller._setExpanded(n.extent > _AymaChatModalSheet._expandedAbove);
    return false;
  }

  /// 1 while docked (or smaller), easing to 0 at full screen: scales the
  /// corner radius and the drag pill so both melt away as the sheet fills
  /// the screen and come back as it shrinks.
  static double _dockedness(double size) => ((_AymaChatModalSheet.fullSize -
              size) /
          (_AymaChatModalSheet.fullSize - _AymaChatModalSheet.dockedSize))
      .clamp(0.0, 1.0);

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
        final nearest = _snapSizes.reduce(
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
    final sizes = _snapSizes;
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
    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        // A fresh `ScaffoldMessenger` scope for everything below — see
        // `showAymaChatModal`'s doc for why this matters (the embedded
        // `ChatScreen`'s own `Scaffold` would otherwise double up any
        // `SnackBar` with whichever `Scaffold` sits under this modal).
        child: ScaffoldMessenger(
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
                child: NotificationListener<DraggableScrollableNotification>(
                  onNotification: _onSheetSize,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _available = constraints.maxHeight;
                      // With a bar (or the keyboard) below it, the sheet no
                      // longer reaches the screen's bottom edge, so the
                      // system inset is the bar's to pad, not the sheet's:
                      // left in, the embedded composer's own SafeArea would
                      // add it a second time.
                      return MediaQuery(
                        data: MediaQuery.of(context)
                            .removeViewInsets(removeBottom: true)
                            .removePadding(
                              removeBottom: bar != null || viewInsets.bottom > 0,
                            ),
                        child: DraggableScrollableSheet(
                          controller: _sheetController,
                          expand: false,
                          initialChildSize: _AymaChatModalSheet.dockedSize,
                          minChildSize: sizes.first,
                          maxChildSize: sizes.last,
                          snap: true,
                          snapSizes: sizes,
                          builder: (context, scrollController) =>
                              _sheetContent(ac, scrollController),
                        ),
                      );
                    },
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
      ),
    );
    // System back while expanded collapses back to the docked sheet instead
    // of closing it (the reverse of expand); while docked it closes as
    // before.
    return _AymaChatSheetScope(
      controller: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, child) => PopScope<Object?>(
          canPop: !_controller.isExpanded,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _controller.collapse();
          },
          child: child!,
        ),
        child: sheet,
      ),
    );
  }

  Widget _sheetContent(AymaTokens ac, ScrollController scrollController) {
    final content = Column(
      children: [
        // The drag-handle dock — a real, if content-less, Scrollable wired
        // to the sheet's own `scrollController`, so a drag starting exactly
        // here resizes the sheet through `DraggableScrollableSheet`'s
        // completely standard mechanism. Kept at full screen too (only its
        // pill fades) so a drag down from the top still collapses.
        SizedBox(
          key: const ValueKey('aymaChatModalHandle'),
          height: 32,
          child: ListView(
            controller: scrollController,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _size,
                    builder: (context, size, pill) =>
                        Opacity(opacity: _dockedness(size), child: pill),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ac.boundary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          // Forces bouncy (iOS-style) overscroll physics for the chat's own
          // list even on Android, whose platform-default clamping physics
          // silently drops position updates once a scroll hits its boundary
          // — no `ScrollUpdateNotification` at all beyond that point, which
          // would starve `_bridgeChatDrag` of the very deltas it needs once
          // the user keeps dragging past the edge.
          child: ScrollConfiguration(
            behavior: const _BouncingScrollBehavior(),
            child: NotificationListener<ScrollNotification>(
              onNotification: _bridgeChatDrag,
              child: Builder(builder: widget.builder),
            ),
          ),
        ),
      ],
    );
    return ValueListenableBuilder<double>(
      valueListenable: _size,
      child: FadeTransition(opacity: _fade, child: content),
      builder: (context, size, child) {
        final docked = _dockedness(size);
        final edge = BorderSide(
          color: ac.boundary.withValues(alpha: ac.boundary.a * docked),
          width: 0.5,
        );
        // How far the sheet's top edge has risen into the status bar: the
        // content is pushed down by exactly that much, so the header slides
        // up until it meets the status bar and then stays put while the
        // surface itself keeps growing underneath it.
        final sheetTop = (1 - size) * _available;
        final statusBarOverlap = (widget.topInset - sheetTop).clamp(
          0.0,
          widget.topInset,
        );
        return DecoratedBox(
          // The sheet's visible box — keyed so tests can measure its actual
          // rendered edges (bottom flush with the reserved bar area / route
          // bottom), not just its size. See the anchoring note on the Stack
          // in [build].
          key: const ValueKey('aymaChatModalSheetBox'),
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(_AymaChatModalSheet._cornerRadius * docked),
            ),
            border: Border(top: edge, left: edge, right: edge),
          ),
          child: Padding(
            padding: EdgeInsets.only(top: statusBarOverlap),
            child: child,
          ),
        );
      },
    );
  }
}

class _BouncingScrollBehavior extends MaterialScrollBehavior {
  const _BouncingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics();
}
