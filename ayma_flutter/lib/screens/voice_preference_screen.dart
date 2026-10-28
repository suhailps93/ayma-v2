import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
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
          const SizedBox(height: 16),
          VoiceEngineControl(api: api ?? ApiClient()),
        ],
      ),
    );
  }
}
