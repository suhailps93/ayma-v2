import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/voice_session_controller.dart';
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
/// `POST /voice/preference`; a changed language (any model) or a changed accent
/// (accent-capable models only) also hot-swaps the live call when one is active
/// (§13.9); everything else takes effect on the next voice call.
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

  // Last-saved accent/language (§13.9 hot-swap): only a save that actually
  // changes one of these nudges the live call; a voice/stack-only save never
  // rebuilds the running session.
  String _savedAccent = '';
  String _savedLanguageCode = '';

  // Free-text ACCENT field (§13.9). Its own controller so typing keeps the
  // caret; the selection's `accent` is the source of truth on save.
  final TextEditingController _accentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _accentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cat = await widget.api.voiceEngines();
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _sel = _normalize(cat, cat.current);
        _accentCtrl.text = _sel!.accent;
        _savedAccent = _sel!.accent;
        _savedLanguageCode = _sel!.languageCode;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Whether the active component (realtime model, or the cascade TTS) honours a
  /// free-text accent (§13.9). Gates whether the ACCENT card renders at all: a
  /// fixed-accent model hides it entirely (the saved value is kept, not cleared).
  bool _activeSupportsAccent() {
    final cat = _cat!, sel = _sel!;
    if (sel.mode == 'realtime') {
      return cat.realtimeById(sel.realtimeModelId)?.supportsAccent ?? false;
    }
    return cat.ttsById(sel.ttsId)?.supportsAccent ?? false;
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

  /// The saved language LABEL for the current selection (the server stores
  /// the label in `ayma_voice_language`); '' when the code has no label.
  String _languageLabel() {
    final code = _sel!.languageCode;
    for (final l in _activeLanguages()) {
      if (l.code == code) return l.label;
    }
    return '';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final sel = _sel!;
      await widget.api.saveVoicePreference(sel);
      // The accent/language changed mid-call: nudge the live agent (if any)
      // so THIS call hot-swaps instead of waiting for the next one (§13.9).
      // Best effort — the save itself already succeeded.
      //
      // A LANGUAGE change always nudges (a fixed-accent TTS can still switch
      // language live). An ACCENT change only nudges when the active component
      // can honour a free-text accent — a fixed-accent model must NOT announce
      // an accent change it would silently ignore. The accent is still
      // persisted above (hide-don't-delete); it simply isn't applied to a live
      // call here. We only advance the saved-accent bookkeeping when the accent
      // was actually honoured, so switching back to an accent-capable model
      // still re-applies the accent on the next save.
      final supportsAccent = _activeSupportsAccent();
      final accentChanged = sel.accent != _savedAccent;
      final languageChanged = sel.languageCode != _savedLanguageCode;
      var appliedLive = false;
      if (languageChanged || (accentChanged && supportsAccent)) {
        try {
          appliedLive = await VoiceSessionController.active
                  ?.notifyVoiceAccentChanged(
                accent: sel.accent,
                language: _languageLabel(),
              ) ??
              false;
        } catch (_) {
          appliedLive = false;
        }
        _savedLanguageCode = sel.languageCode;
        if (supportsAccent) _savedAccent = sel.accent;
      }
      if (mounted) {
        AymaToast.show(
          context,
          appliedLive
              ? 'Voice saved — accent applied to your current call.'
              : 'Voice saved — starts on your next call.',
        );
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
      Builder(builder: (_) {
        // Same rule as the cascade pickers: hide realtime models the user
        // can't select rather than showing them disabled.
        final shown = [for (final m in cat.realtimeModels) if (m.available) m];
        return _dropdown<String>(
          ac,
          value: shown.any((m) => m.id == sel.realtimeModelId)
              ? sel.realtimeModelId
              : (shown.isNotEmpty ? shown.first.id : null),
          items: [
            for (final m in shown)
              DropdownMenuItem(
                value: m.id,
                child: Text(m.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: shown.isEmpty
              ? null
              : (v) {
                  setState(() {
                    _sel = sel.copyWith(realtimeModelId: v);
                    _reconcileVoice();
                  });
                },
        );
      }),
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
        _label(ac, 'LANGUAGE'),
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
        // §13.9: show the ACCENT card ONLY when the active component (the
        // realtime model, or the cascade TTS) can honour a free-text accent.
        // A fixed-accent model renders nothing here — no card and no orphan
        // helper note. The saved accent value is kept (hide-don't-delete), so
        // switching back to an accent-capable model restores it.
        if (_activeSupportsAccent()) ...[
          const SizedBox(height: 12),
          _accentField(ac, sel),
        ],
      ],
    );
  }

  /// A dedicated free-text ACCENT box (§13.9): the user types HOW Ayma should
  /// sound ("southern American accent", "California accent"). Saved as
  /// `ayma_voice_accent` and used by accent-capable models at the start of every
  /// call so the accent never reverts to the default. No fixed height — the
  /// field sizes to its content inside the scrolling list, so it stays matrix-
  /// safe at text scale 2.0 / with the keyboard up.
  Widget _accentField(AymaTokens ac, VoiceSelection sel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'ACCENT'),
        TextField(
          key: const ValueKey('voice-accent-field'),
          controller: _accentCtrl,
          enabled: !_saving,
          minLines: 1,
          maxLines: 2,
          maxLength: 200,
          textInputAction: TextInputAction.done,
          // setState so a later model/mode switch rebuilds its handlers from a
          // selection that already carries the typed accent — otherwise a
          // sibling dropdown's stale closure would overwrite it (§13.9
          // hide-don't-delete). The controller keeps the caret across rebuilds.
          onChanged: (v) => setState(() => _sel = sel.copyWith(accent: v)),
          style: AymaType.sans(size: 15, color: ac.fg),
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: 'e.g. southern American accent',
            hintStyle: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: ac.lineSoft),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: ac.lineSoft),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Ayma speaks with this accent from the first word of every call.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
    );
  }

  Widget _componentDropdown(AymaTokens ac, List<VoiceComponent> items,
      String value, ValueChanged<String?> onChanged) {
    // Only ever list providers the user can actually pick (§ founder
    // 2026-10-28: "if it's not selectable why bother adding"). The catalog
    // still reports the unavailable ones truthfully — they're just not shown.
    final shown = [for (final c in items) if (c.available) c];
    return _dropdown<String>(
      ac,
      value: shown.any((c) => c.id == value)
          ? value
          : (shown.isNotEmpty ? shown.first.id : null),
      items: [
        for (final c in shown)
          DropdownMenuItem(
            value: c.id,
            child: Text(c.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: shown.isEmpty ? null : onChanged,
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
