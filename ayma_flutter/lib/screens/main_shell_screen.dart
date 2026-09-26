import 'package:flutter/material.dart';

import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/call_background_service.dart';
import '../services/chat_inbox.dart';
import '../services/tab_request.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../widgets/ask_ayma_overlay.dart';
import '../widgets/ayma_tab_bar.dart';
import 'chat_screen.dart';
import 'explore_screen.dart';
import 'messages_screen.dart';
import 'profile_tab_screen.dart';

/// The real 4-tab app shell (§11.3, §11.6 step 3, §14.3 Main shell):
/// Ayma / Explore / Messages / Profile. The Ayma tab icon is the brand orb,
/// alive while a voice session is connecting or live. The notification bell
/// lives in the bar itself now, as a 5th, push-only entry (§ founder
/// feedback: move it out of every tab's own header into one place) — it
/// doesn't switch the `IndexedStack`'s page like the four real tabs, since
/// Notifications isn't one of the shell's persistent tab bodies; it just
/// pushes the route, same as any other non-tab screen.
///
/// The one [TranscriptStore] + [VoiceSessionController] for the whole app
/// (see [AymaSession]) are read here by default so the voice session (and the
/// orb's glow) survive tab switches; the Ayma tab is handed both.
///
/// This tab is the app's *sole* full-screen home for Ayma chat — the
/// redundant floating top-right launcher (`GlobalAymaLauncher`, formerly
/// mounted above this screen) was removed (founder feedback: two ways to
/// reach the same chat was confusing). Every other screen in the app instead
/// reaches Ayma through the persistent nav bar `NavBarShell` wraps them with
/// (`nav_bar_shell.dart`, wired in `app_router.dart`) — but tapping that
/// orb no longer routes back here: it opens the scoped page-context popup
/// (`ask_ayma_overlay.dart`'s `showPageContextAymaPopup`) instead, carrying
/// whatever screen the user was actually on (founder ask: "like the story
/// edit" popup, not a full navigation). The orb here in this shell's own bar
/// gets the identical treatment via [_onTabTap] whenever it's tapped from a
/// tab that isn't already Ayma's own.
class MainShellScreen extends StatefulWidget {
  const MainShellScreen({
    super.key,
    this.voiceController,
    this.transcriptStore,
  });

  static const path = '/';

  /// Test-only injection point (mirrors [ChatScreen]'s own
  /// `voiceController`/`transcriptStore` params) — production always lets the
  /// shell fall through to the shared [AymaSession].
  final VoiceSessionController? voiceController;
  final TranscriptStore? transcriptStore;

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen>
    with ScreenContextReasserter<MainShellScreen> {
  // Test-only overrides aside, both default to the single app-wide session
  // (see [AymaSession]) — shared with the global floating chat sheet, so a
  // voice call or history started from either surface is the same one.
  late final TranscriptStore _store =
      widget.transcriptStore ?? AymaSession.instance.store;
  late final VoiceSessionController _voice =
      widget.voiceController ?? AymaSession.instance.voice;

  int _index = 0;
  // Which tabs the user has visited, oldest first, no consecutive repeats. The
  // Android back button walks this back one step at a time instead of leaving
  // the app; only a back press with the Ayma tab as the sole entry exits.
  final List<int> _tabHistory = [0];
  // Tabs are built on first visit and then kept alive — a not-yet-visited tab
  // is an empty box, so nothing touches its services until the user goes there.
  late final List<Widget?> _built = List<Widget?>.filled(4, null)
    ..[0] = ChatScreen(transcriptStore: _store, voiceController: _voice);

  // Explore stays alive (see [_built]) rather than rebuilding each visit, so
  // its data can go stale while you're elsewhere — recalculating a match
  // report, liking someone from their profile. This key lets a returning
  // visit pull fresh data instead of showing whatever it fetched once, the
  // first time the tab was ever built.
  final _exploreKey = GlobalKey<ExploreScreenState>();

  static const _tabScreens = ['ayma', 'explore', 'messages', 'profile_tab'];

  /// [AymaTabBar]'s `onSelected` here — the orb tap gets special treatment
  /// (founder ask: opening it from another tab should pop up the scoped
  /// "Ask Ayma" chat, not jump to the main Ayma tab); the other three tabs
  /// behave exactly as before, straight through to [_selectTab]. A second orb
  /// tap while that popup is already open (its own on-top copy of this same
  /// bar, wired to this same method — see [_navBar]) dismisses it and lands
  /// on the real Ayma tab instead of stacking a second popup (founder ask,
  /// round 2) — checked first, ahead of the "already on the Ayma tab" case
  /// below, since the popup can be open regardless of which tab is current.
  void _onTabTap(int i) {
    if (i == 0 && isPageContextAymaPopupOpen) {
      Navigator.of(context).pop();
      _selectTab(0);
      return;
    }
    if (i == 0 && _index != 0) {
      showPageContextAymaPopup(context, navBarBuilder: _navBar);
    } else {
      _selectTab(i);
    }
  }

  /// Reused verbatim (same `onSelected`) as [showPageContextAymaPopup]'s
  /// `navBarBuilder` — see [_onTabTap]'s doc — so the on-top copy the popup
  /// renders behaves identically to this shell's own `bottomNavigationBar`,
  /// including a tap on it deciding to dismiss the popup and navigate rather
  /// than opening a second one.
  Widget _navBar(BuildContext context) {
    return ListenableBuilder(
      listenable: _voice,
      builder: (context, _) => AymaTabBar(
        index: _index,
        voice: _voice,
        onSelected: _onTabTap,
      ),
    );
  }

  void _selectTab(int i) {
    final alreadyBuilt = _built[i] != null;
    // Snapshot *before* the switch below overwrites it — whatever the user
    // was just looking at (another tab, or a pushed route that popped back
    // to one) is what the Ayma tab's context chip should name.
    final leavingToAyma = i == 0 && _index != 0;
    final prior = AppContext.instance.current.value;
    setState(() {
      _tab(i);
      if (_tabHistory.isEmpty || _tabHistory.last != i) _tabHistory.add(i);
      _index = i;
    });
    AppContext.instance.set(screen: _tabScreens[i]);
    if (i == 1 && alreadyBuilt) _exploreKey.currentState?.reload();
    // `_index` is already 0 above, so `ChatInbox`'s own `_toAymaTab` listener
    // (below) won't re-enter `_selectTab` when this kickoff lands — it only
    // acts while `_index != 0`.
    if (leavingToAyma && prior.screen.isNotEmpty && prior.screen != 'ayma') {
      ChatInbox.instance.push(ChatKickoff.pageContext(prior));
    }
  }

  /// Popping a pushed route (settings, a profile, …) reveals whichever tab was
  /// showing — put it back on the voice mirror.
  @override
  void reassertScreenContext() =>
      AppContext.instance.set(screen: _tabScreens[_index]);

  /// Back pressed with nothing above the shell: step back through tab history.
  /// Returns true when it handled the press (so the app should not close).
  bool _popTab() {
    if (_tabHistory.length <= 1) return false;
    _tabHistory.removeLast();
    final target = _tabHistory.last;
    setState(() => _index = target);
    if (target == 1) _exploreKey.currentState?.reload();
    return true;
  }

  @visibleForTesting
  bool popTabForTest() => _popTab();

  /// Drives the same tab-history mechanism [AymaTabBar]'s Explore/Messages/
  /// Profile tabs do, without going through the orb's now-special-cased tap
  /// handling (see [_onTabTap]) — lets tests exercise [_popTab] with more
  /// than one tab (Explore/Ayma both need no Firebase) the same way a
  /// [TabRequest] arrival already does in production.
  @visibleForTesting
  void selectTabForTest(int i) => _selectTab(i);

  Widget _tab(int i) {
    return _built[i] ??= switch (i) {
      1 => ExploreScreen(key: _exploreKey),
      2 => const MessagesScreen(),
      3 => const ProfileTabScreen(),
      _ => const SizedBox.shrink(),
    };
  }

  late final CallBackgroundService _callBackground = CallBackgroundService(
    _voice,
  );

  @override
  void initState() {
    super.initState();
    AppContext.instance.set(screen: _tabScreens[_index]);
    // A "button → skill in the Ayma chat" hand-off from any other tab or
    // screen (deep dive today) surfaces here as a jump to the Ayma tab; the
    // chat screen itself consumes the kickoff.
    ChatInbox.instance.pending.addListener(_toAymaTab);
    // A screen pushed on top of the shell — `NavBarShell`-wrapped (every
    // other screen in the app) or, like `PublicProfileScreen`, carrying its
    // own identical-looking bar — hands off which tab to land on through
    // this one-slot request rather than a live method call: routing here is
    // flat (no `ShellRoute` nesting), so `context.go(MainShellScreen.path)`
    // tears this screen down and rebuilds it from scratch, leaving no live
    // `State` to call a tab-select method on directly. Consumed both live
    // (already showing, a request arrives while mounted) and on first build
    // (a request landed before this screen existed) — no request pending (a
    // cold launch, a deep link, the Ayma tab's own nav-bar tap while already
    // in the shell) just keeps the default 0 — see F3, "launches directly
    // into the Ayma tab".
    TabRequest.instance.pending.addListener(_consumeTabRequest);
    _consumeTabRequest();
    // F4: backgrounding during a live call surfaces a real OS call UI — an
    // ongoing notification with Hang Up / Mute on Android, a CallKit call on
    // iOS — so the call is always visible and controllable, never silently
    // holding the mic with nothing on screen.
    _callBackground.start();
  }

  void _toAymaTab() {
    if (mounted && ChatInbox.instance.pending.value != null && _index != 0) {
      _selectTab(0);
    }
  }

  void _consumeTabRequest() {
    final target = TabRequest.instance.consume();
    if (target != null && target != _index) _selectTab(target);
  }

  @override
  void dispose() {
    ChatInbox.instance.pending.removeListener(_toAymaTab);
    TabRequest.instance.pending.removeListener(_consumeTabRequest);
    _callBackground.dispose();
    // Unlike a standalone [ChatScreen], this screen never owns [_voice] /
    // [_store] outright any more — the no-override default is the shared,
    // never-disposed [AymaSession] singleton, and a test override is the
    // caller's to dispose.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _tabHistory.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popTab();
      },
      child: Scaffold(
        // A live call keeps running (in this app, not backgrounded to the
        // OS — that's CallBackgroundService) no matter which tab is on
        // screen. Returning to it needs no dedicated "tap to return" pill
        // here: the Ayma tab's own orb below already reflects live call
        // state (glow/pulse) and is the one tap back to it, from this shell
        // or, via `NavBarShell`'s identical-looking bar, from anywhere else
        // in the app.
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < 4; i++) _built[i] ?? const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: _navBar(context),
      ),
    );
  }
}
