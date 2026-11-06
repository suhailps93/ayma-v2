import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/brain_selector_control.dart';
import '../widgets/voice_engine_control.dart';

/// Ayma's models screen (§13.3, §13.9, §13.10). ONE Brain picker drives both
/// text chat and the voice LLM (there is no separate voice brain); the Voice
/// section keeps mode, speech-to-text, text-to-speech, voice, and language &
/// accent. ONE save button persists the whole screen in a single action
/// (`POST /models/preference`): labelled "Save" when no voice session is
/// connected, "Save and reconnect" when a voice call is active — saving
/// mid-call persists, then reconnects the voice session on the new stack
/// (the reconnect itself is silent; Ayma then says she's back, reconnected,
/// with the new model).
class VoicePreferenceScreen extends StatefulWidget {
  const VoicePreferenceScreen({super.key, this.api, this.voiceConnected});

  static const path = '/settings/voice';

  final ApiClient? api;

  /// Test seam: overrides how the screen decides a voice session is
  /// connected (the save button's label + behaviour). Defaults to the
  /// process-wide active voice session.
  final bool Function()? voiceConnected;

  @override
  State<VoicePreferenceScreen> createState() => _VoicePreferenceScreenState();
}

class _VoicePreferenceScreenState extends State<VoicePreferenceScreen> {
  final BrainSelectorController _brainCtl = BrainSelectorController();
  final VoiceEngineController _voiceCtl = VoiceEngineController();
  late final ApiClient _client = widget.api ?? ApiClient();
  bool _saving = false;

  bool get _voiceConnected =>
      widget.voiceConnected?.call() ??
      (VoiceSessionController.active?.isActive ?? false);

  @override
  void initState() {
    super.initState();
    _brainCtl.addListener(_onCtlChanged);
    _voiceCtl.addListener(_onCtlChanged);
    VoiceSessionController.activeNotifier.addListener(_onCtlChanged);
  }

  @override
  void dispose() {
    _brainCtl.removeListener(_onCtlChanged);
    _voiceCtl.removeListener(_onCtlChanged);
    VoiceSessionController.activeNotifier.removeListener(_onCtlChanged);
    _brainCtl.dispose();
    _voiceCtl.dispose();
    super.dispose();
  }

  void _onCtlChanged() {
    if (mounted) setState(() {});
  }

  bool get _ready => _brainCtl.ready && _voiceCtl.ready;

  Future<void> _saveAll() async {
    final brain = _brainCtl.selected;
    final sel = _voiceCtl.selection;
    if (_saving || brain == null || brain.isEmpty || sel == null) return;
    final connected = _voiceConnected;
    setState(() => _saving = true);
    try {
      await _client.saveModelsPreference(
        brain: brain,
        selection: sel,
        reconnect: connected,
      );
      _voiceCtl.markSaved();
      if (!mounted) return;
      if (connected) {
        // Persisted first, then reconnect on the new stack. The server
        // marked the one-shot reconnect announcement in the save above, so
        // the new session speaks the settled "I'm back" line; the teardown
        // itself stays silent.
        await VoiceSessionController.active?.reconnect();
        if (mounted) {
          AymaToast.show(
            context,
            'Models saved — reconnecting your call on the new stack.',
          );
        }
      } else {
        AymaToast.show(
          context,
          'Models saved — your brain starts on your next message, '
          'your voice stack on your next call.',
        );
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Could not save ($e).',
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final connected = _voiceConnected;
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
            'Your brain applies to text right away; a voice change starts '
            'on your next call, or right away if you save and reconnect '
            'during a call. She still follows you if you switch languages '
            'mid-chat.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 20),
          // BRAIN — the ONE LLM that drives every text surface AND the
          // voice cascade (§13.10, one-brain ruling 2026-11-06).
          _sectionHeader(ac, 'Brain',
              'The one LLM behind Ayma — chat, matches, DM tips, '
              'translation, and her voice on a call. Image reading and web '
              'research always use Gemini.'),
          const SizedBox(height: 12),
          BrainSelectorControl(
            api: _client,
            controller: _brainCtl,
            showSaveButton: false,
          ),
          const SizedBox(height: 28),
          Divider(color: ac.lineSoft, height: 1),
          const SizedBox(height: 24),
          // VOICE — mode / STT / TTS / voice / language & accent (§13.9).
          // No brain picker here any more: the Brain above is the voice LLM.
          _sectionHeader(ac, 'Voice',
              'How Ayma listens and speaks on a call. Her voice thinks '
              'with the Brain above.'),
          const SizedBox(height: 12),
          VoiceEngineControl(
            api: _client,
            controller: _voiceCtl,
            showSaveButton: false,
          ),
          const SizedBox(height: 24),
          // THE one save button for the whole screen.
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('models-save'),
              onPressed: (_saving || !_ready) ? null : _saveAll,
              child: _saving
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : Text(connected ? 'Save and reconnect' : 'Save'),
            ),
          ),
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
