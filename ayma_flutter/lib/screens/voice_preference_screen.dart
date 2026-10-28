import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/brain_selector_control.dart';
import '../widgets/voice_engine_control.dart';

/// Ayma's voice settings (§13.3, §13.9). This is the user-facing home of the
/// full voice stack control: mode (Cascade / Realtime), brain (LLM),
/// speech-to-text, text-to-speech, voice, and language & accent — all from the
/// **cloud catalog** (`GET /voice/engines`), live, so new providers appear with
/// no client change. It replaced the old Gemini-preset-only voice picker and is
/// reachable from the normal Ayma settings menu (no longer developer-gated).
/// A change takes effect from the next voice call.
class VoicePreferenceScreen extends StatelessWidget {
  const VoicePreferenceScreen({super.key, this.api});

  static const path = '/settings/voice';

  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final client = api ?? ApiClient();
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Ayma’s models'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Text(
            'Switch Ayma’s model stack — how she thinks, listens and speaks. '
            'A change takes effect on your next voice call. She still follows '
            'you if you switch languages mid-chat.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 20),
          // BRAIN — the one LLM that drives every text surface (§13.10). Sits
          // above the Voice section; the two are independent preferences.
          _sectionHeader(ac, 'Brain',
              'The LLM behind Ayma’s text — chat, matches, DM tips and '
              'translation. Image reading and web research always use Gemini.'),
          const SizedBox(height: 12),
          BrainSelectorControl(api: client),
          const SizedBox(height: 28),
          Divider(color: ac.lineSoft, height: 1),
          const SizedBox(height: 24),
          // VOICE — unchanged stack control (§13.9).
          _sectionHeader(ac, 'Voice',
              'How Ayma listens and speaks on a call.'),
          const SizedBox(height: 12),
          VoiceEngineControl(api: client),
        ],
      ),
    );
  }

  Widget _sectionHeader(AymaTokens ac, String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: AymaType.sans(size: 18, weight: FontWeight.w600, color: ac.fg)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        ],
      );
}
