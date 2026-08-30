import 'package:flutter/material.dart';

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
/// glowing while a voice session is connecting or live. The notification bell
/// lives in each tab's own app bar.
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
  // Tabs are built on first visit and then kept alive — a not-yet-visited tab
  // is an empty box, so nothing touches its services until the user goes there.
  late final List<Widget?> _built = List<Widget?>.filled(4, null)
    ..[0] = ChatScreen(transcriptStore: _store, voiceController: _voice);

  Widget _tab(int i) {
    return _built[i] ??= switch (i) {
      1 => const ExploreScreen(),
      2 => const MessagesScreen(),
      3 => const ProfileTabScreen(),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  void dispose() {
    _voice.dispose();
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < 4; i++)
            _built[i] ?? const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _voice,
        builder: (context, _) => NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() {
            _tab(i);
            _index = i;
          }),
          destinations: [
            NavigationDestination(
              icon: AymaOrb(size: 22, active: _voice.isActive),
              selectedIcon: AymaOrb(size: 24, active: _voice.isActive),
              label: 'Ayma',
            ),
            const NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: 'Explore',
            ),
            const NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: 'Messages',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline, color: ac.fgMute),
              selectedIcon: const Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
