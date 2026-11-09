import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/voice_session_controller.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/brain_selector_control.dart';
import '../widgets/image_model_selector_control.dart';
import '../widgets/voice_engine_control.dart';

/// Ayma's models screen (§13.3, §13.9, §13.10). ONE Brain picker drives both
/// text chat and the voice LLM (there is no separate voice brain); the voice
/// pickers keep mode, speech-to-text, text-to-speech, voice, and language &
/// accent. ONE save button persists the whole screen in a single action
/// (`POST /models/preference`): labelled "Save" when no voice session is
/// connected, "Save and reconnect" when a voice call is active — saving
/// mid-call persists, then reconnects the voice session on the new stack
/// (the reconnect itself is silent; Ayma then says she's back, reconnected,
/// with the new model).
///
/// The list is FLAT (founder, 2026-11-07): no Brain/Voice section headers
/// and no explanation paragraphs — each picker's short explanation sits
/// behind its info icon (see `PickerInfoLabel`).
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
  final ImageModelController _imageCtl = ImageModelController();
  final VoiceEngineController _voiceCtl = VoiceEngineController();
  late final ApiClient _client = widget.api ?? ApiClient();
  bool _saving = false;
  String? _savedBrain;
  String? _savedImage;
  VoiceSelection? _savedSelection;

  bool get _voiceConnected =>
      widget.voiceConnected?.call() ??
      (VoiceSessionController.active?.isActive ?? false);

  @override
  void initState() {
    super.initState();
    _brainCtl.addListener(_onCtlChanged);
    _imageCtl.addListener(_onCtlChanged);
    _voiceCtl.addListener(_onCtlChanged);
    VoiceSessionController.activeNotifier.addListener(_onCtlChanged);
  }

  @override
  void dispose() {
    _brainCtl.removeListener(_onCtlChanged);
    _imageCtl.removeListener(_onCtlChanged);
    _voiceCtl.removeListener(_onCtlChanged);
    VoiceSessionController.activeNotifier.removeListener(_onCtlChanged);
    _brainCtl.dispose();
    _imageCtl.dispose();
    _voiceCtl.dispose();
    super.dispose();
  }

  void _onCtlChanged() {
    if (mounted) {
      if (_savedBrain == null && _brainCtl.selected != null) {
        _savedBrain = _brainCtl.selected;
      }
      if (_savedImage == null && _imageCtl.selected != null) {
        _savedImage = _imageCtl.selected;
      }
      if (_savedSelection == null && _voiceCtl.selection != null) {
        _savedSelection = _voiceCtl.selection;
      }
      setState(() {});
    }
  }

  bool get _ready => _brainCtl.ready && _imageCtl.ready && _voiceCtl.ready;

  bool get _isDirty {
    final sb = _savedBrain;
    final ss = _savedSelection;
    if (sb == null || ss == null) return false;
    final b = _brainCtl.selected;
    final s = _voiceCtl.selection;
    if (b == null || s == null) return false;
    // The image model is optional: it only contributes to dirtiness once both
    // a baseline and a current value exist (a single-model catalog never
    // changes, so it stays clean on its own).
    final imgDirty = _savedImage != null &&
        _imageCtl.selected != null &&
        _imageCtl.selected != _savedImage;
    return b != sb || s != ss || imgDirty;
  }

  bool get _canSave => !_saving && _ready && (_voiceConnected || _isDirty);

  Future<void> _saveAll() async {
    final brain = _brainCtl.selected;
    final sel = _voiceCtl.selection;
    if (_saving || brain == null || brain.isEmpty || sel == null) return;
    final image = _imageCtl.selected ?? '';
    final connected = _voiceConnected;
    setState(() => _saving = true);
    try {
      await _client.saveModelsPreference(
        brain: brain,
        selection: sel,
        imageModel: image,
        reconnect: connected,
      );
      _savedBrain = brain;
      _savedImage = _imageCtl.selected;
      _savedSelection = sel;
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
    final connected = _voiceConnected;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Ayma’s models'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          // BRAIN — the ONE LLM that drives every text surface AND the
          // voice cascade (§13.10, one-brain ruling 2026-11-06).
          BrainSelectorControl(
            api: _client,
            controller: _brainCtl,
            showSaveButton: false,
          ),
          const SizedBox(height: 24),
          // VOICE pickers — mode / STT / TTS / voice / language & accent
          // (§13.9). No brain picker here: the Brain above is the voice LLM.
          VoiceEngineControl(
            api: _client,
            controller: _voiceCtl,
            showSaveButton: false,
          ),
          const SizedBox(height: 24),
          // IMAGE MODEL — which model Ayma uses to create/edit images in chat
          // (image-gen restore, 2026-11-08). Its own per-user setting,
          // independent of the Brain and the voice stack; the ONE
          // founder-authorized direct-provider path, Gemini-direct default.
          ImageModelSelectorControl(
            api: _client,
            controller: _imageCtl,
            showSaveButton: false,
          ),
          const SizedBox(height: 24),
          // THE one save button for the whole screen.
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('models-save'),
              onPressed: _canSave ? _saveAll : null,
              child: _saving
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : Text(connected ? 'Save and reconnect' : 'Save'),
            ),
          ),
        ],
      ),
    );
  }
}
