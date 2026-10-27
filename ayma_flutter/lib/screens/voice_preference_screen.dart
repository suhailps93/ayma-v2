import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/voice_engine_control.dart';

/// Pick the voice Ayma speaks with (§13.3, §13.9). The voices + accent/language
/// come from the **same cloud catalog** (`GET /voice/engines`) as the developer
/// "Voice engine" control, for whichever engine is currently active — so it
/// works on every engine (Gemini Live, the Meta cascade, …), not just Gemini.
/// The engine/stack itself is chosen in developer settings; here the user only
/// picks the voice and accent. A change takes effect from the next voice call.
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
        title: const Text('Ayma’s voice'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Text(
            'Choose how Ayma sounds. A new voice starts at your next voice '
            'call. She still follows you if you switch languages mid-chat.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 16),
          VoiceEngineControl(
            api: api ?? ApiClient(),
            fullStack: false,
          ),
        ],
      ),
    );
  }
}
