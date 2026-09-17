import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../routing/app_router.dart';
import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import 'ayma_orb.dart';

/// The app-wide floating "Ask Ayma" button — the Gemini-in-Gmail affordance,
/// in this app's own brand (an [AymaOrb], not a generic FAB icon). Mounted
/// once above the router (`MaterialApp.router`'s `builder`), not inside any
/// one screen, so it stays visible across every route — the 4-tab shell and
/// every pushed screen (profile, explore, a match report, a DM thread, the
/// Story editor, …) alike.
///
/// Tapping it opens the real Ayma chat — [ChatScreen] wired to the single
/// app-wide [AymaSession] (same [TranscriptStore] and
/// [VoiceSessionController] the Ayma tab uses, so history and any live call
/// are identical) — in a draggable bottom sheet: drag up for near-full
/// height, drag to a half-open resting size, or drag down past the minimum
/// to dismiss, mirroring the Gemini-in-Gmail reference the founder pointed
/// at. It carries the page the user was on when they opened it
/// ([AppContext.instance]'s current [ScreenContext], reused as-is — not a
/// second context mechanism) into that chat.
///
/// Suppressed — [IgnorePointer]/[ExcludeSemantics]'d, not just faded, so it
/// never steals a tap or a screen-reader stop — whenever opening it would be
/// redundant: while its own sheet is already open, and while the Ayma tab
/// itself is already the screen on show (the tab shell already mirrors its
/// current tab onto [AppContext.instance] on every switch — reused here
/// rather than adding a second "which tab" signal).
class GlobalAymaLauncher extends StatefulWidget {
  const GlobalAymaLauncher({
    super.key,
    this.navigatorKey,
    this.signedIn,
    this.apiClient,
  });

  /// The `Navigator` to open the sheet on. Defaults to the app's single
  /// [appRouter]'s own key. This widget is mounted as a *sibling* of the
  /// router's own subtree (`MaterialApp.router`'s `builder`, so it survives
  /// every navigation — see the class doc) rather than a descendant of it,
  /// so its own `BuildContext` has no `Navigator` ancestor to call
  /// `showModalBottomSheet` against; a test-only override lets a widget test
  /// point this at its own small local router instead of the real app's.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Test-only override for the sign-in gate below — bypasses
  /// `FirebaseAuth.instance` entirely (unavailable, uninitialised, in a
  /// plain widget test) when non-null.
  final bool? signedIn;

  /// Test-only override handed straight to the sheet's embedded
  /// [ChatScreen] — without it, opening the sheet in a test hits a real
  /// [ApiClient] and a real network call, the same reason every other
  /// embedded-`ChatScreen` sheet in this app (e.g. the Story editor's "Chat
  /// about it") is always given a fake one in tests.
  final ApiClient? apiClient;

  @override
  State<GlobalAymaLauncher> createState() => _GlobalAymaLauncherState();
}

class _GlobalAymaLauncherState extends State<GlobalAymaLauncher> {
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    AppContext.instance.current.addListener(_onScreenContextChanged);
  }

  @override
  void dispose() {
    AppContext.instance.current.removeListener(_onScreenContextChanged);
    super.dispose();
  }

  /// `AppContext.instance.set(...)` runs from plenty of screens' own
  /// `initState` (`ScreenContextReasserter`) — since this widget's own
  /// `ValueListenable` subscription lives *outside* the route currently
  /// mounting (a sibling in `MaterialApp.router`'s own `builder`, per the
  /// class doc), a notification can land mid-build, and a bare `setState`
  /// here would throw ("setState() or markNeedsBuild() called during
  /// build" — not a descendant of whatever's currently building). Deferring
  /// to the next frame when that's the case is the standard fix.
  void _onScreenContextChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _open() async {
    if (_sheetOpen) return;
    final navContext =
        (widget.navigatorKey ?? appRouter.routerDelegate.navigatorKey)
            .currentContext;
    if (navContext == null) return;
    setState(() => _sheetOpen = true);
    // A one-time snapshot of wherever the user was — not a live mirror — the
    // same way a pushed `ChatScreen` route's own context params already work.
    final pageContext = AppContext.instance.current.value;
    await showModalBottomSheet<void>(
      context: navContext,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _AymaFloatingSheet(
        pageContext: pageContext,
        apiClient: widget.apiClient,
      ),
    );
    // The sheet's own embedded `ChatScreen` unconditionally sets `screen:
    // 'ayma'` in its `initState` (so a live voice call can answer "what am
    // I on?"), same as every other embedded-chat sheet in this app — but
    // closing a *bottom sheet* route doesn't run the underlying screen's own
    // `ScreenContextReasserter` (that only re-asserts on a `PageRoute` pop),
    // so without this, the mirror would stay stuck on 'ayma' and this
    // button would wrongly stay hidden on whatever screen the user returns
    // to. Restore the exact snapshot this sheet opened with.
    AppContext.instance.set(
      screen: pageContext.screen,
      subjectUid: pageContext.subjectUid,
      subjectName: pageContext.subjectName,
      note: pageContext.note,
    );
    if (mounted) setState(() => _sheetOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    // Signed-out screens (splash, sign-in, terms, privacy, recovery — the
    // same "open" set `app_router.dart`'s own redirect gate lists) never show
    // the button: there's no Ayma session to open yet, and `AppContext`
    // alone wouldn't catch a sign-out that lands on one of them without also
    // setting a new screen context. `authStateChanges` covers that.
    if (widget.signedIn != null) {
      return widget.signedIn! ? _afterAuth() : const SizedBox.shrink();
    }
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data ?? FirebaseAuth.instance.currentUser;
        final signedIn = user != null && !user.isAnonymous;
        return signedIn ? _afterAuth() : const SizedBox.shrink();
      },
    );
  }

  // Screens with no real Ayma session to open yet — same reasoning as the
  // signed-out gate above, for the signed-in-but-still-loading window
  // (§ founder report: the button showing over the splash screen's loading
  // orb while `/bootstrap` is still in flight, after auth already
  // succeeded, so the signed-out check alone doesn't catch it).
  static const _hiddenScreens = {'ayma', 'splash'};

  Widget _afterAuth() {
    final screenCtx = AppContext.instance.current.value;
    final visible = !_sheetOpen && !_hiddenScreens.contains(screenCtx.screen);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: visible ? 1 : 0,
          child: Align(
            alignment: Alignment.bottomRight,
            // `minimum` guarantees clearance above a bottom nav bar / a
            // per-screen FAB (only Photos has one) even on a device whose own
            // safe-area inset is 0.
            child: SafeArea(
              minimum: const EdgeInsets.only(bottom: 90, right: 16),
              child: ListenableBuilder(
                listenable: AymaSession.instance.voice,
                builder: (context, _) => _LauncherButton(
                  voice: AymaSession.instance.voice,
                  onTap: _open,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LauncherButton extends StatelessWidget {
  const _LauncherButton({required this.voice, required this.onTap});

  final VoiceSessionController voice;
  final VoidCallback onTap;

  // Same phase -> orb-state mapping the app's other live-call orb readouts
  // use (e.g. the Ayma tab bar icon) — this button should read the live call
  // exactly the same way.
  AymaOrbState _orbState() {
    return switch (voice.phase) {
      VoiceSessionPhase.connecting ||
      VoiceSessionPhase.waking => AymaOrbState.thinking,
      VoiceSessionPhase.live =>
        voice.agentSpeaking ? AymaOrbState.speaking : AymaOrbState.listening,
      VoiceSessionPhase.idle || VoiceSessionPhase.error => AymaOrbState.idle,
    };
  }

  /// The orb's own painted size — bigger than the original 30px per the
  /// founder's "make this larger" feedback, still well inside the `_Tier
  /// .small` band (`ayma_orb.dart`, <80) so it keeps the compact FAB look
  /// rather than picking up the glow/rings reserved for medium+ sizes.
  static const _orbSize = 48.0;

  /// Extra padding around the orb so the tap target clears Flutter's ~48dp
  /// minimum-touch-size guideline even though the *visible* orb (with no
  /// filled backdrop behind it any more) is all a viewer sees — the padding
  /// itself stays fully transparent.
  static const _tapPadding = 8.0;

  @override
  Widget build(BuildContext context) {
    // No `Material`/backdrop fill here on purpose — the founder was
    // explicit, twice, that the dark circle behind the orb (`ac.bgElev`,
    // near-black in dark theme) had to go. `AymaOrb` already paints its own
    // glow/shadow, so all this needs is enough `Material` to keep the ripple
    // and `Semantics` button behavior, with a transparent color and no
    // elevation/shadow of its own.
    return Material(
      type: MaterialType.transparency,
      shape: const CircleBorder(),
      child: Semantics(
        button: true,
        label: 'Ask Ayma',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(_tapPadding),
            child: AymaOrb(size: _orbSize, state: _orbState()),
          ),
        ),
      ),
    );
  }
}

/// The draggable chat sheet — a `DraggableScrollableSheet` (the same pattern
/// `body_report_view.dart` / `face_report_view.dart` already use), sized to
/// approximate the Gemini-in-Gmail reference: opens at roughly half height,
/// snaps to near-full on drag-up, and — `showModalBottomSheet` + a
/// scroll-controller-linked `DraggableScrollableSheet`'s standard, built-in
/// behavior — dragging down past the minimum size dismisses it.
///
/// Stateful (not the plain `StatelessWidget` this used to be) so it can own
/// a [DraggableScrollableController] — see [_bridgeChatDrag] for why.
class _AymaFloatingSheet extends StatefulWidget {
  const _AymaFloatingSheet({required this.pageContext, this.apiClient});

  final ScreenContext pageContext;
  final ApiClient? apiClient;

  static const _sizes = [0.42, 0.62, 0.95];

  @override
  State<_AymaFloatingSheet> createState() => _AymaFloatingSheetState();
}

class _AymaFloatingSheetState extends State<_AymaFloatingSheet> {
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
  /// [ChatScreen] here deliberately gets its *own*, independent
  /// `ScrollController` (not this sheet's) precisely so this bridge can
  /// drive [_sheetController] from the chat's raw drag deltas without
  /// racing the chat list's own in-flight drag — sharing one `ScrollPosition`
  /// between the two would make every `jumpTo` below dispose (and thereby
  /// cancel) whatever `DragScrollActivity` the user's own finger is still
  /// driving on that same position, chopping the gesture into one tiny,
  /// unrepeatable step per frame.
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
        final nearest = _AymaFloatingSheet._sizes.reduce(
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
    final sizes = _AymaFloatingSheet._sizes;
    return DraggableScrollableSheet(
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
            // No explicit close ("X") button any more — founder feedback:
            // redundant once dragging down past the minimum dismisses it
            // (`shouldCloseOnMinExtent`, on by default).
            SizedBox(
              key: const ValueKey('aymaSheetHandle'),
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
                  child: ChatScreen(
                    apiClient: widget.apiClient,
                    transcriptStore: AymaSession.instance.store,
                    voiceController: AymaSession.instance.voice,
                    viewingProfileUid: widget.pageContext.screen == 'profile'
                        ? widget.pageContext.subjectUid
                        : '',
                    pageContext: widget.pageContext,
                    // No `scrollController` here on purpose — see
                    // `_bridgeChatDrag`'s doc.
                  ),
                ),
              ),
            ),
          ],
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
