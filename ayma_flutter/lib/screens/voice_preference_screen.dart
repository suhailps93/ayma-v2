import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../services/voice_preview_player.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/overflow_guards.dart';

/// Pick the Gemini Live voice preset Ayma speaks with (§13.3, §13.8 step 5).
/// Tapping a preset selects it *and* plays a short spoken sample in that voice
/// ("Hi, I'm Ayma…") so the choice isn't blind. The change itself takes effect
/// from the next voice session (Gemini Live sets the voice at session start).
class VoicePreferenceScreen extends StatefulWidget {
  const VoicePreferenceScreen({
    super.key,
    this.api,
    this.profileService,
    this.previewPlayer,
  });

  static const path = '/settings/voice';

  final ApiClient? api;
  final ProfileService? profileService;
  final VoicePreviewPlayer? previewPlayer;

  @override
  State<VoicePreferenceScreen> createState() => _VoicePreferenceScreenState();
}

class _VoicePreferenceScreenState extends State<VoicePreferenceScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final VoicePreviewPlayer _player =
      widget.previewPlayer ?? JustAudioPreviewPlayer();

  VoicePresets? _data;
  String? _error;
  String? _selected;
  final _langController = TextEditingController();
  bool _saving = false;

  /// The preset whose preview is currently resolving / playing, if any.
  String? _previewing;

  /// Incremented per preview tap; only the latest request may touch state.
  int _previewSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _showSnack(String message,
      {AymaToastKind kind = AymaToastKind.info}) {
    AymaToast.show(context, message, kind: kind);
  }

  @override
  void dispose() {
    // Toasts live above the Navigator: this screen's must not outlive it.
    AymaToast.hide();
    _langController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await _api.voicePresets();
      if (mounted) {
        setState(() {
          _data = d;
          _selected = d.effective;
          _langController.text = d.currentLanguage;
        });
        _prewarmPreviews(d);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Ask the backend to synth (and cache) every preview now, so a tap plays
  /// near-instantly instead of waiting on a cold TTS call. Fire-and-forget.
  void _prewarmPreviews(VoicePresets d) {
    for (final p in d.presets) {
      _api.voicePreviewUrl(p.name).catchError((_) => '');
    }
  }

  Future<void> _choose(String name) async {
    final previous = _selected;
    setState(() {
      _selected = name;
      _saving = true;
    });
    try {
      await _profiles.setVoicePreference(name);
    } catch (e) {
      if (mounted) {
        setState(() => _selected = previous);
        _showSnack('Could not save ($e).', kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveLang() async {
    final text = _langController.text.trim();
    if (text == (_data?.currentLanguage.trim() ?? '')) return; // unchanged
    setState(() => _saving = true);
    try {
      await _profiles.setVoiceLanguage(text);
    } catch (e) {
      if (mounted) {
        _showSnack('Could not save ($e).',
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _preview(String name) async {
    final seq = ++_previewSeq;
    setState(() => _previewing = name);
    try {
      // Stop whatever is making sound first: a preview already playing, and a
      // live voice call if one is running in the background.
      await _player.stop();
      final call = VoiceSessionController.active;
      if (call != null && call.isActive) {
        await call.stop();
        if (mounted && seq == _previewSeq) {
          _showSnack('Ended the call to play this preview.');
        }
      }
      final url = await _api.voicePreviewUrl(name);
      if (!mounted || seq != _previewSeq) return; // superseded by a newer tap
      await _player.play(url);
    } catch (_) {
      if (mounted && seq == _previewSeq) {
        _showSnack("Couldn't play a preview.",
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted && seq == _previewSeq) setState(() => _previewing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Ayma’s voice')),
      body: _error != null
          ? CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load voices ($_error).',
                  style: AymaType.sans(size: 14, color: AymaColors.error)),
            )
          : _data == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  // iOS has no keyboard-dismiss key — dragging the list away
                  // is the native escape hatch.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      child: Text('LANGUAGE & ACCENT',
                          style: AymaType.mono(size: 10, color: ac.fgMute)
                              .copyWith(letterSpacing: 1.5)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: TextField(
                        controller: _langController,
                        enabled: !_saving,
                        textInputAction: TextInputAction.done,
                        onEditingComplete: () {
                          FocusScope.of(context).unfocus();
                          _saveLang();
                        },
                        onTapOutside: (_) {
                          FocusScope.of(context).unfocus();
                          _saveLang();
                        },
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: _data!.languageExamples.isEmpty
                              ? 'e.g. Malayalam mixed with English'
                              : 'e.g. ${_data!.languageExamples.first}',
                          suffixIcon: _saving
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.check, size: 18),
                                  onPressed: () {
                                    FocusScope.of(context).unfocus();
                                    _saveLang();
                                  },
                                ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Text(
                        _data!.currentLanguage.isEmpty
                            ? 'Type how Ayma should speak — any accent, '
                                'language, or mix ("Malayalam and English", '
                                '"a Southern US accent"). She still follows you '
                                'if you switch languages mid-conversation.'
                            : 'Ayma’s current default: "${_data!.currentLanguage}"'
                                ' — set here or from talking with her. She '
                                'still follows you if you switch mid-conversation.',
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute),
                      ),
                    ),
                    Divider(color: ac.lineSoft, height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      child: Text('VOICE',
                          style: AymaType.mono(size: 10, color: ac.fgMute)
                              .copyWith(letterSpacing: 1.5)),
                    ),
                    RadioGroup<String>(
                      groupValue: _selected,
                      onChanged: (v) {
                        _choose(v!);
                        _preview(v);
                      },
                      child: Column(
                        children: [
                          for (final p in _data!.presets)
                            RadioListTile<String>(
                              value: p.name,
                              enabled: !_saving,
                              secondary: SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: _previewing == p.name
                                      ? const AymaOrb(
                                          size: 18,
                                          state: AymaOrbState.speaking)
                                      : IconButton(
                                          icon: const Icon(
                                              Icons.volume_up_outlined,
                                              size: 20),
                                          color: ac.fgMute,
                                          tooltip: 'Hear ${p.name}',
                                          onPressed: _saving
                                              ? null
                                              : () => _preview(p.name),
                                        ),
                                ),
                              ),
                              title: Text(p.name,
                                  style: AymaType.sans(size: 15, color: ac.fg)),
                              subtitle: Text(p.description,
                                  style: AymaType.sans(
                                      size: 12, soft: true, color: ac.fgMute)),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Text(
                        'Tap a voice to hear a sample. A new voice starts at '
                        'your next voice session — Ayma can’t switch voices '
                        'mid-call.',
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute),
                      ),
                    ),
                  ],
                ),
    );
  }
}
