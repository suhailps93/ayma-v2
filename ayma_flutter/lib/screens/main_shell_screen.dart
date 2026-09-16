import 'package:flutter/material.dart';

import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/call_background_service.dart';
import '../services/chat_inbox.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import 'chat_screen.dart';
import 'explore_screen.dart';
import 'messages_screen.dart';
import 'profile_tab_screen.dart';

/// The real 4-tab app shell (§11.3, §11.6 step 3, §14.3 Main shell):
/// Ayma / Explore / Messages / Profile. The Ayma tab icon is the brand orb,
/// alive while a voice session is connecting or live. The notification bell
/// lives in each tab's own header.
///
/// The one [TranscriptStore] + [VoiceSessionController] for the whole app
/// (see [AymaSession]) are read here by default so the voice session (and the
/// orb's glow) survive tab switches; the Ayma tab is handed both. The global
/// floating chat sheet ([GlobalAymaLauncher], mounted above this screen in
/// the router's builder) embeds the same two instances, so history and any
/// live call are identical whichever surface reached them.
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

  static const _tabScreens = ['ayma', 'explore', 'messages', 'profile_tab'];

  void _selectTab(int i) {
    setState(() {
      _tab(i);
      if (_tabHistory.isEmpty || _tabHistory.last != i) _tabHistory.add(i);
      _index = i;
    });
    AppContext.instance.set(screen: _tabScreens[i]);
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
    setState(() => _index = _tabHistory.last);
    return true;
  }

  @visibleForTesting
  bool popTabForTest() => _popTab();

  Widget _tab(int i) {
    return _built[i] ??= switch (i) {
      1 => const ExploreScreen(),
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

  @override
  void dispose() {
    ChatInbox.instance.pending.removeListener(_toAymaTab);
    _callBackground.dispose();
    // Unlike a standalone [ChatScreen], this screen never owns [_voice] /
    // [_store] outright any more — the no-override default is the shared,
    // never-disposed [AymaSession] singleton (reachable from the global
    // floating sheet too), and a test override is the caller's to dispose.
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
        // screen. Returning to it from another tab used to need a dedicated
        // "tap to return" pill here; the app-wide floating launcher
        // (`GlobalAymaLauncher`, mounted above this screen) now serves that
        // exact purpose — its own orb already reflects live call state and
        // opens the same shared session — so the pill was removed as
        // redundant (founder feedback).
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < 4; i++) _built[i] ?? const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: ListenableBuilder(
          listenable: _voice,
          builder: (context, _) => _AymaTabBar(
            index: _index,
            voiceActive: _voice.isActive,
            onSelected: _selectTab,
          ),
        ),
      ),
    );
  }
}

/// The bottom tab bar in the Ayma design language: a translucent bar with a top
/// hairline and four plain icons — no text labels, so the chat composer above
/// it gets the extra breathing room. The first tab carries the living orb
/// instead of an icon. Each tab keeps its name as a [Tooltip] (long-press /
/// screen-reader accessible) even though it's no longer painted on screen.
class _AymaTabBar extends StatelessWidget {
  const _AymaTabBar({
    required this.index,
    required this.voiceActive,
    required this.onSelected,
  });

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
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _labels.length; i++)
                _Tab(
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
          child: SizedBox(height: 24, width: 24, child: Center(child: icon)),
        ),
      ),
    );
  }
}
