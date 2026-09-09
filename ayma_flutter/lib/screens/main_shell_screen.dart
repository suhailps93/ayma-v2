import 'package:flutter/material.dart';

import '../services/chat_inbox.dart';
import '../services/ids.dart';
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
/// A single [TranscriptStore] + [VoiceSessionController] are owned here so the
/// voice session (and the orb's glow) survive tab switches; the Ayma tab is
/// handed both.
class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  static const path = '/';

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  final _sessionId = newSessionId();
  late final TranscriptStore _store = TranscriptStore();
  late final VoiceSessionController _voice = VoiceSessionController(
    transcriptStore: _store,
    sessionId: _sessionId,
  );

  int _index = 0;
  // Which tabs the user has visited, oldest first, no consecutive repeats. The
  // Android back button walks this back one step at a time instead of leaving
  // the app; only a back press with the Ayma tab as the sole entry exits.
  final List<int> _tabHistory = [0];
  // Tabs are built on first visit and then kept alive — a not-yet-visited tab
  // is an empty box, so nothing touches its services until the user goes there.
  late final List<Widget?> _built = List<Widget?>.filled(4, null)
    ..[0] = ChatScreen(transcriptStore: _store, voiceController: _voice);

  void _selectTab(int i) {
    setState(() {
      _tab(i);
      if (_tabHistory.isEmpty || _tabHistory.last != i) _tabHistory.add(i);
      _index = i;
    });
  }

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

  @override
  void initState() {
    super.initState();
    // A "button → skill in the Ayma chat" hand-off from any other tab or
    // screen (deep dive today) surfaces here as a jump to the Ayma tab; the
    // chat screen itself consumes the kickoff.
    ChatInbox.instance.pending.addListener(_toAymaTab);
  }

  void _toAymaTab() {
    if (mounted && ChatInbox.instance.pending.value != null && _index != 0) {
      _selectTab(0);
    }
  }

  @override
  void dispose() {
    ChatInbox.instance.pending.removeListener(_toAymaTab);
    _voice.dispose();
    _store.dispose();
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
/// hairline, thin icons, and mono all-caps letter-spaced labels. The first tab
/// carries the living orb instead of an icon.
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
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _labels.length; i++)
                _Tab(
                  label: _labels[i],
                  active: index == i,
                  onTap: () => onSelected(i),
                  icon: i == 0
                      ? AymaOrb(size: 22, active: voiceActive)
                      : Icon(
                          (index == i ? _icons[i]!.$2 : _icons[i]!.$1),
                          size: 20,
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
  const _Tab({
    required this.label,
    required this.active,
    required this.onTap,
    required this.icon,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 22, child: Center(child: icon)),
            const SizedBox(height: 6),
            Text(
              label.toUpperCase(),
              style: AymaType.mono(
                size: 9,
                weight: active ? FontWeight.w500 : FontWeight.w400,
                color: active ? ac.fg : ac.fgMute,
              ).copyWith(letterSpacing: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
