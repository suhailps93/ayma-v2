import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'ayma_toast.dart';

/// The voice STACK picker (ARCHITECTURE §13.9). Reads `GET /voice/engines` and
/// lets the user choose:
///
/// * a MODE — **Realtime** (one native-audio model) or **Cascade** (independent
///   brain / STT / TTS);
/// * in realtime: the realtime model, then its voices + accent/language;
/// * in cascade: brain, STT, TTS, then the TTS's voices + accent/language.
///
/// Dropdown contents are pulled from the cloud catalog (LiveKit Inference, live),
/// so new providers appear without a client change. Saving calls
/// `POST /voice/preference`; it takes effect on the next voice call.
///
/// This is the user-facing "Ayma's voice" control (ARCHITECTURE §13.9): it shows
/// the whole stack — mode, brain, STT, TTS, voice and language — so a normal user
/// gets full control from Ayma settings. Unavailable components (e.g. OpenAI
/// Realtime with no key) stay labelled and non-selectable via the catalog's
/// `available`/`requires_secret` contract.
class VoiceEngineControl extends StatefulWidget {
  const VoiceEngineControl({
    super.key,
    required this.api,
    this.onSaved,
  });

  final ApiClient api;
  final VoidCallback? onSaved;

  @override
  State<VoiceEngineControl> createState() => _VoiceEngineControlState();
}

class _VoiceEngineControlState extends State<VoiceEngineControl> {
  VoiceCatalog? _cat;
  VoiceSelection? _sel;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cat = await widget.api.voiceEngines();
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _sel = _normalize(cat, cat.current);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Fill any missing component ids from the catalog defaults so the dropdowns
  /// always have a concrete value and a save is always valid.
  VoiceSelection _normalize(VoiceCatalog cat, VoiceSelection sel) {
    final d = cat.defaultSelection;
    final mode = cat.modes.contains(sel.mode) ? sel.mode : d.mode;
    String realtime = sel.realtimeModelId.isNotEmpty
        ? sel.realtimeModelId
        : d.realtimeModelId;
    if (cat.realtimeById(realtime) == null && cat.realtimeModels.isNotEmpty) {
      realtime = cat.realtimeModels.first.id;
    }
    String brain = _pick(cat.brains, sel.brainId, d.brainId);
    String stt = _pick(cat.stt, sel.sttId, d.sttId);
    String tts = _pick(cat.tts, sel.ttsId, d.ttsId);
    return sel.copyWith(
      mode: mode,
      realtimeModelId: realtime,
      brainId: brain,
      sttId: stt,
      ttsId: tts,
    );
  }

  String _pick(List<VoiceComponent> items, String chosen, String fallback) {
    bool has(String id) => items.any((c) => c.id == id);
    if (chosen.isNotEmpty && has(chosen)) return chosen;
    if (fallback.isNotEmpty && has(fallback)) return fallback;
    return items.isNotEmpty ? items.first.id : '';
  }

  List<CatalogVoice> _activeVoices() {
    final cat = _cat!, sel = _sel!;
    if (sel.mode == 'realtime') {
      return cat.realtimeById(sel.realtimeModelId)?.voices ?? const [];
    }
    return cat.ttsById(sel.ttsId)?.voices ?? const [];
  }

  List<CatalogLanguage> _activeLanguages() {
    final cat = _cat!, sel = _sel!;
    if (sel.mode == 'realtime') {
      return cat.realtimeById(sel.realtimeModelId)?.languages ?? const [];
    }
    return cat.ttsById(sel.ttsId)?.languages ?? const [];
  }

  /// Keep the chosen voice valid for the active component; clear it otherwise.
  void _reconcileVoice() {
    final voices = _activeVoices();
    if (!voices.any((v) => v.id == _sel!.voiceId)) {
      _sel = _sel!.copyWith(voiceId: voices.isNotEmpty ? voices.first.id : '');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.api.saveVoicePreference(_sel!);
      if (mounted) {
        AymaToast.show(context, 'Voice saved — starts on your next call.');
        widget.onSaved?.call();
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
    if (_error != null) {
      return Text('Could not load voices ($_error).',
          key: const ValueKey('voice-engine-error'),
          style: AymaType.sans(size: 13, color: AymaColors.error));
    }
    if (_cat == null || _sel == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final cat = _cat!, sel = _sel!;
    _reconcileVoice();
    return Column(
      key: const ValueKey('voice-engine-control'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'MODE'),
        _dropdown<String>(
          ac,
          value: sel.mode,
          items: [
            for (final m in cat.modes)
              DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
          ],
          onChanged: (m) => setState(() => _sel = sel.copyWith(mode: m)),
        ),
        const SizedBox(height: 16),
        if (sel.mode == 'realtime')
          ..._realtimeControls(ac, cat, sel)
        else
          ..._cascadeControls(ac, cat, sel),
        const SizedBox(height: 8),
        _voiceAndLanguage(ac, cat, sel),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const ValueKey('voice-engine-save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save voice'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            cat.source == 'livekit'
                ? 'Options are pulled live from LiveKit Inference. A new '
                    'voice starts on your next call.'
                : 'Showing the built-in option list (live catalog '
                    'unavailable). A new voice starts on your next call.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
      ],
    );
  }

  List<Widget> _realtimeControls(
      AymaTokens ac, VoiceCatalog cat, VoiceSelection sel) {
    return [
      _label(ac, 'REALTIME MODEL'),
      _dropdown<String>(
        ac,
        value: sel.realtimeModelId,
        items: [
          for (final m in cat.realtimeModels)
            DropdownMenuItem(
              value: m.id,
              enabled: m.available,
              child: Text(
                m.available
                    ? m.label
                    : '${m.label} (needs ${m.requiresSecret})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          setState(() {
            _sel = sel.copyWith(realtimeModelId: v);
            _reconcileVoice();
          });
        },
      ),
    ];
  }

  List<Widget> _cascadeControls(
      AymaTokens ac, VoiceCatalog cat, VoiceSelection sel) {
    return [
      _label(ac, 'BRAIN (LLM)'),
      _componentDropdown(ac, cat.brains, sel.brainId,
          (v) => setState(() => _sel = sel.copyWith(brainId: v))),
      const SizedBox(height: 12),
      _label(ac, 'SPEECH-TO-TEXT'),
      _componentDropdown(ac, cat.stt, sel.sttId,
          (v) => setState(() => _sel = sel.copyWith(sttId: v))),
      const SizedBox(height: 12),
      _label(ac, 'TEXT-TO-SPEECH'),
      _componentDropdown(ac, cat.tts, sel.ttsId, (v) {
        setState(() {
          _sel = sel.copyWith(ttsId: v);
          _reconcileVoice();
        });
      }),
    ];
  }

  Widget _voiceAndLanguage(
      AymaTokens ac, VoiceCatalog cat, VoiceSelection sel) {
    final voices = _activeVoices();
    final langs = _activeLanguages();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'VOICE'),
        _dropdown<String>(
          ac,
          dropdownKey: const ValueKey('voice-dropdown'),
          value: voices.any((v) => v.id == sel.voiceId)
              ? sel.voiceId
              : (voices.isNotEmpty ? voices.first.id : null),
          items: [
            for (final v in voices)
              DropdownMenuItem(
                value: v.id,
                child: Text(
                  v.description.isEmpty ? v.label : '${v.label} — ${v.description}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: voices.isEmpty
              ? null
              : (v) => setState(() => _sel = sel.copyWith(voiceId: v)),
        ),
        const SizedBox(height: 12),
        _label(ac, 'LANGUAGE & ACCENT'),
        _dropdown<String>(
          ac,
          value: langs.any((l) => l.code == sel.languageCode)
              ? sel.languageCode
              : '',
          items: [
            for (final l in langs)
              DropdownMenuItem(value: l.code, child: Text(l.label)),
          ],
          onChanged: langs.isEmpty
              ? null
              : (v) => setState(() => _sel = sel.copyWith(languageCode: v ?? '')),
        ),
      ],
    );
  }

  Widget _componentDropdown(AymaTokens ac, List<VoiceComponent> items,
      String value, ValueChanged<String?> onChanged) {
    return _dropdown<String>(
      ac,
      value: items.any((c) => c.id == value)
          ? value
          : (items.isNotEmpty ? items.first.id : null),
      items: [
        for (final c in items)
          DropdownMenuItem(
            value: c.id,
            enabled: c.available,
            child: Text(
              c.available ? c.label : '${c.label} (needs ${c.requiresSecret})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: items.isEmpty ? null : onChanged,
    );
  }

  Widget _label(AymaTokens ac, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.5)),
      );

  Widget _dropdown<T>(
    AymaTokens ac, {
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    Key? dropdownKey,
  }) {
    // DropdownButton asserts its value is among the items (or null); coerce to
    // null when the catalog is empty or the value isn't present.
    final effective =
        items.any((i) => i.value == value) ? value : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: ac.lineSoft),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<T>(
        key: dropdownKey,
        value: effective,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: items,
        onChanged: _saving ? null : onChanged,
        style: AymaType.sans(size: 15, color: ac.fg),
      ),
    );
  }

  String _modeLabel(String m) => m == 'cascade'
      ? 'Cascade (brain + STT + TTS)'
      : 'Realtime (native audio)';
}
