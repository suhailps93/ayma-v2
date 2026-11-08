import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/voice_preview_player.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The voice STACK picker (ARCHITECTURE §13.9). Reads `GET /voice/engines` and
/// lets the user choose:
///
/// * a MODE — **Realtime** (one native-audio model) or **Cascade** (STT +
///   the one Brain + TTS);
/// * in realtime: the realtime model, then its voices + accent/language;
/// * in cascade: STT, TTS, then the TTS's voices + accent/language.
///
/// ONE BRAIN (founder, 2026-11-06): there is NO brain picker in this
/// section any more — the Models screen's single Brain (see
/// `BrainSelectorControl`) is the voice LLM too, resolved server-side from
/// the one saved brain selection.
///
/// Dropdown contents are pulled from the cloud catalog (LiveKit Inference, live),
/// so new providers appear without a client change. Saving calls
/// `POST /voice/preference`; a changed language (any model) or a changed accent
/// (accent-capable models only) also hot-swaps the live call when one is active
/// (§13.9); everything else takes effect on the next voice call. On the Models
/// screen the screen owns the single save button ([showSaveButton] false +
/// a [VoiceEngineController]) and saves through `POST /models/preference`.
///
/// This is the user-facing "Ayma's voice" control (ARCHITECTURE §13.9): it shows
/// the voice stack — mode, STT, TTS, voice and language — so a normal user
/// gets full control from Ayma settings. Unavailable components (e.g. OpenAI
/// Realtime with no key) stay labelled and non-selectable via the catalog's
/// `available`/`requires_secret` contract.
class VoiceEngineControl extends StatefulWidget {
  const VoiceEngineControl({
    super.key,
    required this.api,
    this.onSaved,
    this.firestore,
    this.uid,
    this.controller,
    this.showSaveButton = true,
    this.previewPlayer,
  });

  final ApiClient api;
  final VoidCallback? onSaved;
  final VoiceEngineController? controller;
  final bool showSaveButton;

  /// Test seam for the voice-sample preview player; defaults to the real
  /// just_audio player. The control owns and disposes the instance it uses.
  final VoicePreviewPlayer? previewPlayer;

  /// Test seams for the live-update listener; default to the app globals.
  final FirebaseFirestore? firestore;
  final String? uid;

  @override
  State<VoiceEngineControl> createState() => _VoiceEngineControlState();
}

/// Lets a parent (the Models screen) read the current voice selection and
/// know when the control has loaded, so ONE screen-level save button can
/// persist every section in a single action.
class VoiceEngineController extends ChangeNotifier {
  _VoiceEngineControlState? _state;

  VoiceSelection? get selection => _state?._sel;
  bool get ready => _state?._cat != null && _state?._sel != null;

  /// After a successful combined save, advance the last-saved
  /// accent/language bookkeeping to the just-saved selection.
  void markSaved() => _state?._markSaved();

  void _attach(_VoiceEngineControlState s) => _state = s;
  void _detach(_VoiceEngineControlState s) {
    if (_state == s) _state = null;
  }

  void _changed() => notifyListeners();
}

class _VoiceEngineControlState extends State<VoiceEngineControl> {
  VoiceCatalog? _cat;
  VoiceSelection? _sel;
  String? _error;
  bool _saving = false;

  // Voice-sample preview (founder feedback 2026-11-07): the play button
  // beside the VOICE dropdown fetches the recorded sample for the
  // dropdown's current (unsaved) choice and plays it through this
  // standalone player. It deliberately never touches
  // VoiceSessionController — a live call keeps running untouched; the
  // sample plays alongside it the way a voice message plays.
  late final VoicePreviewPlayer _previewPlayer =
      widget.previewPlayer ?? JustAudioPreviewPlayer();
  String? _previewingVoiceId;
  bool _previewBusy = false;
  // Voice fallback notice (Part B): true when the shown voice is a
  // supported default the control (or the server) substituted for a saved
  // voice the selected model does not support — never silent.
  bool _voiceFellBack = false;
  String _fallbackFromLabel = '';

  /// True once the catalog load's first attempt has failed and a cold-start
  /// backoff retry is pending/in flight: the loader swaps its line to
  /// "Reconnecting…" instead of holding the original line indefinitely
  /// (loader retest, Nov 2026, Leg 4). Reset on every new load.
  bool _retrying = false;

  // Last-saved accent/language (§13.9 hot-swap): only a save that actually
  // changes one of these nudges the live call; a voice/stack-only save never
  // rebuilds the running session.
  String _savedAccent = '';
  String _savedLanguageCode = '';

  // Free-text ACCENT field (§13.9). Its own controller so typing keeps the
  // caret; the selection's `accent` is the source of truth on save.
  final TextEditingController _accentCtrl = TextEditingController();

  // Live update: when Ayma (or any surface) saves a stack change to the user's
  // model-settings doc, the open screen reflects it at once (founder 2026-11-02).
  // A watched-field change re-fetches `GET /voice/engines`, reusing the server's
  // canonical raw-fields→selection mapping rather than duplicating it here.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  String? _watchedSig;
  Timer? _reloadDebounce;

  // The model-settings doc fields this control renders (§13.9); a change in any
  // of them means Ayma updated the stack and the dropdowns must refresh.
  static const _watchedFields = <String>[
    'ayma_voice_mode',
    'ayma_realtime_model',
    'ayma_cascade_brain',
    'ayma_cascade_stt',
    'ayma_cascade_tts',
    'ayma_tts_voice',
    'ayma_voice_name',
    'ayma_voice_language',
    'ayma_voice_accent',
  ];

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _load();
    _listenForSavedStack();
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _reloadDebounce?.cancel();
    _profileSub?.cancel();
    _accentCtrl.dispose();
    _previewPlayer.dispose();
    super.dispose();
  }

  void _markSaved() {
    final sel = _sel;
    if (sel == null) return;
    _savedAccent = sel.accent;
    _savedLanguageCode = sel.languageCode;
  }

  /// The voice the dropdown currently shows: the selection, reconciled
  /// against the active component's voice list the same way the dropdown's
  /// own effective value is.
  String get _effectiveVoiceId {
    final sel = _sel;
    if (sel == null) return '';
    final voices = _activeVoices();
    if (voices.any((v) => v.id == sel.voiceId)) return sel.voiceId;
    return voices.isNotEmpty ? voices.first.id : '';
  }

  /// Stop any playing sample and forget which voice it was. Called when
  /// the shown voice changes (voice / mode / component switch, catalog
  /// reload) so the button state always matches the voice on screen.
  /// Callers are inside (or immediately beside) a setState.
  void _resetPreview() {
    if (_previewingVoiceId == null) return;
    _previewingVoiceId = null;
    _previewPlayer.stop().catchError((Object _) {});
  }

  /// Play (or stop) the recorded sample for the voice the dropdown is
  /// currently showing — BEFORE anything is saved, so the user hears the
  /// voice before committing to it. Only the built-in Gemini presets have
  /// recorded samples (cached clips server-side); any other voice fails
  /// honestly with a toast instead of pretending. Never reads or mutates
  /// the live voice session: a call in progress is left completely alone.
  Future<void> _togglePreview() async {
    final voiceId = _effectiveVoiceId;
    if (voiceId.isEmpty || _previewBusy) return;
    if (_previewingVoiceId == voiceId) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _previewingVoiceId = null);
      return;
    }
    setState(() => _previewBusy = true);
    try {
      final url = await widget.api.voicePreviewUrl(voiceId);
      if (!mounted) return;
      if (url.isEmpty) throw ApiException('voice preview failed.');
      await _previewPlayer.play(url);
      if (!mounted) return;
      setState(() {
        _previewingVoiceId = voiceId;
        _previewBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewingVoiceId = null;
        _previewBusy = false;
      });
      AymaToast.show(
        context,
        (e is ApiException && (e.statusCode == 404 || e.statusCode == 502))
            ? 'No preview recorded for this voice yet.'
            : 'Could not play a preview of this voice.',
        kind: AymaToastKind.error,
      );
    }
  }

  DocumentReference<Map<String, dynamic>>? _profileRef() {
    // Best-effort: with no Firebase app (unit tests that don't inject a fake),
    // reading the globals throws — caught so the control still renders.
    try {
      final uid = widget.uid ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return null;
      return (widget.firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(uid)
          .collection('profile')
          .doc('main');
    } catch (_) {
      return null;
    }
  }

  /// Refresh the whole control when a stack field changes under us (Ayma's
  /// set_voice_mode / set_realtime_model / set_voice_preference). The first
  /// snapshot only seeds the baseline (initial render is `_load`'s job); a later
  /// change re-fetches the catalog's recomputed `current`. Skipped while saving
  /// so the user's own in-flight edit is never clobbered.
  void _listenForSavedStack() {
    final ref = _profileRef();
    if (ref == null) return;
    try {
      _profileSub = ref.snapshots().listen(_onStackSnap, onError: (_) {});
    } catch (_) {
      // No live updates in this environment; initial _load still rendered.
    }
  }

  void _onStackSnap(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data() ?? const <String, dynamic>{};
    final sig = [for (final f in _watchedFields) '$f=${data[f] ?? ''}']
        .join('|');
    if (_watchedSig == null) {
      _watchedSig = sig;
      return;
    }
    if (sig == _watchedSig) return;
    _watchedSig = sig;
    if (!mounted || _saving) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted && !_saving) _load();
    });
  }

  Future<void> _load() async {
    // Ride through a scale-to-zero cold start (founder bug, 2026-11-03): both
    // the initial open AND the on-brain-switch live re-fetch go through here,
    // and the cold staging backend used to 408 the first `/voice/engines` call
    // into a hard "Could not load voices" error. Now the call uses a
    // cold-start-tolerant timeout and auto-retries with exponential backoff
    // over a generous budget — staying on the loading spinner (initial) or the
    // current dropdowns (re-fetch) — and only a sustained failure surfaces the
    // error + Retry.
    if (mounted && (_error != null || _retrying)) {
      setState(() {
        _error = null;
        _retrying = false;
      });
    }
    try {
      final cat = await withColdStartRetry(
        () => widget.api.voiceEngines(timeout: kColdStartCallTimeout),
        onRetry: () {
          if (mounted) setState(() => _retrying = true);
        },
      );
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _sel = _normalize(cat, cat.current);
        _voiceFellBack = cat.current.voiceFellBack;
        _fallbackFromLabel = cat.current.voiceFellBack
            ? _labelForVoiceId(cat, cat.current.savedVoiceId)
            : '';
        _accentCtrl.text = _sel!.accent;
        _savedAccent = _sel!.accent;
        _savedLanguageCode = _sel!.languageCode;
      });
      _resetPreview();
      widget.controller?._changed();
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
      final previous = _sel!.voiceId;
      _sel = _sel!.copyWith(voiceId: voices.isNotEmpty ? voices.first.id : '');
      // No silent wrong voice: when a model switch drops the user's voice,
      // the note under the dropdown says what happened.
      if (previous.isNotEmpty && voices.isNotEmpty && _cat != null) {
        _fallbackFromLabel = _labelForVoiceId(_cat!, previous);
        _voiceFellBack = true;
      }
    }
  }

  /// A voice id's display label from anywhere in the catalog ('' when the
  /// id is not a catalog voice at all).
  String _labelForVoiceId(VoiceCatalog cat, String voiceId) {
    if (voiceId.isEmpty) return '';
    for (final m in cat.realtimeModels) {
      for (final v in m.voices) {
        if (v.id == voiceId) return v.label;
      }
    }
    for (final t in cat.tts) {
      for (final v in t.voices) {
        if (v.id == voiceId) return v.label;
      }
    }
    return '';
  }

  String _fallbackNoteText() {
    final to = _labelForVoiceId(_cat!, _sel!.voiceId);
    final toText = to.isEmpty ? 'the default voice for this model' : to;
    if (_fallbackFromLabel.isEmpty) {
      return 'Your saved voice is not available with this model, '
          'so we switched to $toText.';
    }
    return '$_fallbackFromLabel is not available with this model, '
        'so we switched to $toText.';
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
          appliedLive =
              await VoiceSessionController.active?.notifyVoiceAccentChanged(
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
        AymaToast.show(
          context,
          'Could not save ($e).',
          kind: AymaToastKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_error != null) {
      // Shown only after the cold-start retry budget is spent (see [_load]);
      // Retry restarts the whole load sequence from scratch.
      return Column(
        key: const ValueKey('voice-engine-error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Could not load voices ($_error).',
            style: AymaType.sans(size: 13, color: AymaColors.error),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    if (_cat == null || _sel == null) {
      // GET /voice/engines (cold-start retries included) still in flight;
      // while a retry is pending/in flight the line says so instead of
      // holding the original line indefinitely.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: AymaWingLoader(
            size: 44,
            lines: _retrying
                ? AymaLoaderLines.reconnect
                : AymaLoaderLines.voiceEngines,
          ),
        ),
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
          onChanged: (m) => setState(() {
            _sel = sel.copyWith(mode: m);
            _resetPreview();
          }),
        ),
        const SizedBox(height: 16),
        if (sel.mode == 'realtime')
          ..._realtimeControls(ac, cat, sel)
        else
          ..._cascadeControls(ac, cat, sel),
        const SizedBox(height: 12),
        _voiceAndLanguage(ac, cat, sel),
        if (widget.showSaveButton) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('voice-engine-save'),
              onPressed: _saving ? null : _save,
              // POST /voice/preference in flight — button slot, wings only.
              child: _saving
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : const Text('Save voice'),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 12),
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
    AymaTokens ac,
    VoiceCatalog cat,
    VoiceSelection sel,
  ) {
    return [
      _label(ac, 'REALTIME MODEL'),
      Builder(
        builder: (_) {
          // Same rule as the cascade pickers: hide realtime models the user
          // can't select rather than showing them disabled.
          final shown = [
            for (final m in cat.realtimeModels)
              if (m.available) m,
          ];
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
                      _resetPreview();
                    });
                  },
          );
        },
      ),
    ];
  }

  List<Widget> _cascadeControls(
    AymaTokens ac,
    VoiceCatalog cat,
    VoiceSelection sel,
  ) {
    // No BRAIN (LLM) dropdown: the one Brain above is the cascade LLM too.
    return [
      _label(ac, 'SPEECH-TO-TEXT'),
      _componentDropdown(
        ac,
        cat.stt,
        sel.sttId,
        (v) => setState(() => _sel = sel.copyWith(sttId: v)),
      ),
      const SizedBox(height: 12),
      _label(ac, 'TEXT-TO-SPEECH'),
      _componentDropdown(ac, cat.tts, sel.ttsId, (v) {
        setState(() {
          _sel = sel.copyWith(ttsId: v);
          _reconcileVoice();
          _resetPreview();
        });
      }),
    ];
  }

  Widget _voiceAndLanguage(
    AymaTokens ac,
    VoiceCatalog cat,
    VoiceSelection sel,
  ) {
    final voices = _activeVoices();
    final langs = _activeLanguages();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'VOICE'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _dropdown<String>(
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
                        v.description.isEmpty
                            ? v.label
                            : '${v.label} — ${v.description}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: voices.isEmpty
                    ? null
                    : (v) => setState(() {
                        _sel = sel.copyWith(voiceId: v);
                        _resetPreview();
                        _voiceFellBack = false;
                      }),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('voice-preview-button'),
              tooltip:
                  _previewingVoiceId != null &&
                      _previewingVoiceId == _effectiveVoiceId
                  ? 'Stop preview'
                  : 'Play a sample of this voice',
              onPressed:
                  (voices.isEmpty || _effectiveVoiceId.isEmpty || _previewBusy)
                  ? null
                  : _togglePreview,
              icon: _previewBusy
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : Icon(
                      _previewingVoiceId != null &&
                              _previewingVoiceId == _effectiveVoiceId
                          ? Icons.stop_circle_outlined
                          : Icons.play_circle_outline,
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Hear a short sample of the voice before you save. Playing a '
          'sample never changes or interrupts a call in progress.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
        if (_voiceFellBack) ...[
          const SizedBox(height: 6),
          Text(
            key: const ValueKey('voice-fallback-note'),
            _fallbackNoteText(),
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ],
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
              : (v) =>
                    setState(() => _sel = sel.copyWith(languageCode: v ?? '')),
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
        const SizedBox(height: 8),
        Text(
          'Ayma speaks with this accent from the first word of every call.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
    );
  }

  Widget _componentDropdown(
    AymaTokens ac,
    List<VoiceComponent> items,
    String value,
    ValueChanged<String?> onChanged,
  ) {
    // Only ever list providers the user can actually pick (§ founder
    // 2026-10-28: "if it's not selectable why bother adding"). The catalog
    // still reports the unavailable ones truthfully — they're just not shown.
    final shown = [
      for (final c in items)
        if (c.available) c,
    ];
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
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: AymaType.mono(
        size: 10,
        color: ac.fgMute,
      ).copyWith(letterSpacing: 1.5),
    ),
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
    final effective = items.any((i) => i.value == value) ? value : null;
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
