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
import 'picker_info_label.dart';

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
    _previewPlayer.onComplete = () {
      if (mounted) {
        setState(() {
          _previewingVoiceId = null;
          _previewBusy = false;
        });
      }
    };
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
    _previewToken++;
    _previewBusy = false;
    if (_previewingVoiceId == null) return;
    _previewingVoiceId = null;
    _previewPlayer.stop().catchError((Object _) {});
  }

  int _previewToken = 0;

  /// Resolves the voice ID to preview: returns the non-empty effective voice
  /// ID, or identifies the vendor default voice from the catalog.
  String _resolvePreviewVoiceId() {
    final effective = _effectiveVoiceId;
    if (effective.isNotEmpty) return effective;

    // Default voice entry: identify the vendor default voice from the catalog.
    final voices = _activeVoices();
    final defaultVoice = voices.where((v) => v.id.isEmpty).firstOrNull;
    if (defaultVoice != null) {
      final match = RegExp(r'Default \((.+)\)').firstMatch(defaultVoice.label);
      if (match != null) {
        final targetName = match.group(1)!.trim().toLowerCase();
        for (final v in voices) {
          if (v.id.isNotEmpty &&
              (v.id.toLowerCase() == targetName ||
                  v.label.toLowerCase() == targetName)) {
            return v.id;
          }
        }
      }
    }

    // Per-TTS fallback from catalog definition:
    final sel = _sel;
    if (sel != null && sel.mode == 'cascade') {
      final ttsId = sel.ttsId.toLowerCase();
      if (ttsId.contains('inworld')) {
        for (final v in voices) {
          if (v.id.toLowerCase() == 'ashley' ||
              v.label.toLowerCase() == 'ashley') {
            return v.id;
          }
        }
      }
    }

    return '';
  }

  /// Play (or stop) the recorded sample for the voice the dropdown is
  /// currently showing — BEFORE anything is saved, so the user hears the
  /// voice before committing to it.
  Future<void> _togglePreview() async {
    final voices = _activeVoices();
    if (voices.isEmpty) return;

    // Tapping again while playing or busy loading cancels/stops immediately.
    if (_previewingVoiceId != null || _previewBusy) {
      _previewToken++;
      await _previewPlayer.stop();
      if (mounted) {
        setState(() {
          _previewingVoiceId = null;
          _previewBusy = false;
        });
      }
      return;
    }

    final voiceId = _resolvePreviewVoiceId();
    if (voiceId.isEmpty) {
      AymaToast.show(
        context,
        'No preview recorded for this voice yet.',
        kind: AymaToastKind.error,
      );
      return;
    }

    final token = ++_previewToken;
    setState(() {
      _previewingVoiceId = _effectiveVoiceId;
      _previewBusy = true;
    });

    try {
      final url = await widget.api.voicePreviewUrl(voiceId);
      if (token != _previewToken) return;
      if (!mounted) return;
      if (url.isEmpty) throw ApiException('voice preview failed.');
      await _previewPlayer.play(url);
      if (token != _previewToken) return;
      if (!mounted) return;
      setState(() {
        _previewBusy = false;
      });
    } catch (e) {
      if (token != _previewToken) return;
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
        const PickerInfoLabel(
          label: 'MODE',
          infoKey: 'picker-info-mode',
          title: 'Mode',
          explanation:
              'How a voice call runs. Realtime is one model that hears '
              'you and speaks back directly. Cascade splits the job: one '
              'service listens, your Brain thinks, another one speaks.',
        ),
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
      ],
    );
  }

  List<Widget> _realtimeControls(
    AymaTokens ac,
    VoiceCatalog cat,
    VoiceSelection sel,
  ) {
    return [
      const PickerInfoLabel(
        label: 'REALTIME MODEL',
        infoKey: 'picker-info-realtime-model',
        title: 'Realtime model',
        explanation:
            'The model that hears you and talks back on a realtime '
            'call \u2014 listening and speaking in one.',
      ),
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
      const PickerInfoLabel(
        label: 'SPEECH-TO-TEXT',
        infoKey: 'picker-info-stt',
        title: 'Speech-to-text',
        explanation:
            'The service that turns your voice into words for the '
            'Brain to read.',
      ),
      _componentDropdown(
        ac,
        cat.stt,
        sel.sttId,
        (v) => setState(() => _sel = sel.copyWith(sttId: v)),
      ),
      const SizedBox(height: 12),
      const PickerInfoLabel(
        label: 'TEXT-TO-SPEECH',
        infoKey: 'picker-info-tts',
        title: 'Text-to-speech',
        explanation:
            'The service that turns Ayma\u2019s words into the speech '
            'you hear.',
      ),
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
        const PickerInfoLabel(
          label: 'VOICE',
          infoKey: 'picker-info-voice',
          title: 'Voice',
          explanation: 'How Ayma sounds when she speaks on a call.',
        ),
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
                  voices.isEmpty
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
        const SizedBox(height: 12),
        const PickerInfoLabel(
          label: 'LANGUAGE',
          infoKey: 'picker-info-language',
          title: 'Language',
          explanation:
              'The language Ayma listens and speaks in on a call. She '
              'still follows you if you switch languages mid-chat.',
        ),
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
        const PickerInfoLabel(
          label: 'ACCENT',
          infoKey: 'picker-info-accent',
          title: 'Accent',
          explanation:
              'Type how you want her to sound \u2014 Ayma speaks with '
              'this accent from the first word of every call.',
        ),
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
