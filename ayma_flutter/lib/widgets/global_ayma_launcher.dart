import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../routing/app_router.dart';
import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/voice_session_controller.dart';
import 'ayma_chat_modal.dart';
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
/// are identical) — in `showAymaChatModal` (`ayma_chat_modal.dart`), the same
/// dockable-chat-modal treatment every "tap to correct" affordance in the app
/// opens too (`ask_ayma_overlay.dart`'s `showAskAymaOverlay`): drag up for
/// near-full height, drag to a half-open resting size, or drag down past the
/// minimum to dismiss, mirroring the Gemini-in-Gmail reference the founder
/// pointed at. It carries the page the user was on when they opened it
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
    await showAymaChatModal(
      navContext,
      // [ChatScreen] gets its *own*, independent `ScrollController` (not the
      // modal's) so `showAymaChatModal`'s own drag-to-resize bridge can drive
      // the sheet from the chat list's raw drag deltas without racing the
      // list's own in-flight drag — see that function's doc.
      builder: (_) => ChatScreen(
        apiClient: widget.apiClient,
        transcriptStore: AymaSession.instance.store,
        voiceController: AymaSession.instance.voice,
        viewingProfileUid: pageContext.screen == 'profile'
            ? pageContext.subjectUid
            : '',
        pageContext: pageContext,
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
            alignment: Alignment.topCenter,
            // `minimum` guarantees clearance below the status bar / notch
            // even on a device whose own safe-area inset is 0 — the founder's
            // ask (screenshot, arrow from the top of the screen down to the
            // orb's old bottom-right spot) was to move this button into the
            // top nav bar, centered, instead of floating bottom-right above
            // the tab bar.
            child: SafeArea(
              minimum: const EdgeInsets.only(top: 8),
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
