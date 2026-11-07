import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The unified **Brain** picker (ARCHITECTURE §13.10). Reads
/// `GET /brain/preference` and lets the user choose the ONE LLM that drives
/// every text surface — chat, matching, DM coaching and cross-language
/// translation. A capability the chosen brain lacks (image reading, live web
/// research) automatically falls back to Gemini, so the choice can never drop a
/// feature; this control just states that in each brain's description.
///
/// Saving calls `POST /brain/preference`; it takes effect on the next text
/// turn. This sits ABOVE the voice stack control on the "Ayma's models"
/// screen. ONE BRAIN (founder, 2026-11-06): this same selection is also the
/// voice cascade's LLM — the Voice section has no brain picker of its own.
/// On the models screen the screen owns the single save button
/// ([showSaveButton] false + a [BrainSelectorController]); standalone use
/// keeps its own save button.
class BrainSelectorControl extends StatefulWidget {
  const BrainSelectorControl({
    super.key,
    required this.api,
    this.onSaved,
    this.firestore,
    this.uid,
    this.controller,
    this.showSaveButton = true,
  });

  final ApiClient api;
  final VoidCallback? onSaved;
  final BrainSelectorController? controller;
  final bool showSaveButton;

  /// Test seams for the live-update listener; default to the app globals.
  final FirebaseFirestore? firestore;
  final String? uid;

  @override
  State<BrainSelectorControl> createState() => _BrainSelectorControlState();
}

/// Lets a parent (the Models screen) read the current Brain selection and
/// know when the control has loaded, so ONE screen-level save button can
/// persist every section in a single action.
class BrainSelectorController extends ChangeNotifier {
  _BrainSelectorControlState? _state;

  String? get selected => _state?._selected;
  bool get ready => _state?._cat != null && _state?._selected != null;

  void _attach(_BrainSelectorControlState s) => _state = s;
  void _detach(_BrainSelectorControlState s) {
    if (_state == s) _state = null;
  }

  void _changed() => notifyListeners();
}

class _BrainSelectorControlState extends State<BrainSelectorControl> {
  BrainCatalog? _cat;
  String? _selected;
  String? _error;
  bool _saving = false;

  /// True once the preference load's first attempt has failed and a
  /// cold-start backoff retry is pending/in flight: the loader swaps its line
  /// to "Reconnecting…" instead of holding the original line indefinitely
  /// (loader retest, Nov 2026, Leg 4). Reset on every new load.
  bool _retrying = false;

  // Live update: when Ayma (or any surface) saves a new brain to the user's
  // model-settings doc (`ayma_brain_model` on users/{uid}/profile/main), the
  // open screen reflects it at once instead of only on reopen (founder 2026-11-02).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  String? _watchedBrain;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _load();
    _listenForSavedBrain();
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _profileSub?.cancel();
    super.dispose();
  }

  DocumentReference<Map<String, dynamic>>? _profileRef() {
    // Best-effort: in a context with no Firebase app (unit tests that don't
    // inject a fake), reading the globals throws — caught by the caller so the
    // control still renders, just without live updates.
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

  /// Reflect a brain change written to the model-settings doc while this screen
  /// is open (e.g. Ayma's `set_brain`). Reads the vendor id directly — the same
  /// field `GET /brain/preference` reads — so no extra round-trip is needed; the
  /// first snapshot only seeds the baseline (initial render is `_load`'s job).
  void _listenForSavedBrain() {
    final ref = _profileRef();
    if (ref == null) return;
    try {
      _profileSub = ref.snapshots().listen(_onBrainSnap, onError: (_) {});
    } catch (_) {
      // No live updates in this environment; initial _load still rendered.
    }
  }

  void _onBrainSnap(DocumentSnapshot<Map<String, dynamic>> snap) {
    final v = (snap.data()?['ayma_brain_model'] as String? ?? '').trim();
    if (_watchedBrain == null) {
      _watchedBrain = v;
      return;
    }
    if (v == _watchedBrain) return;
    _watchedBrain = v;
    if (!mounted || _saving || v.isEmpty) return;
    final cat = _cat;
    if (cat == null || !cat.brains.any((b) => b.id == v)) return;
    setState(() => _selected = v);
    widget.controller?._changed();
  }

  Future<void> _load() async {
    // Ride through a scale-to-zero cold start (founder bug, 2026-11-03): the
    // cold staging backend used to 408 the first `/brain/preference` call into
    // a hard "Could not load brains" error. Now it uses a cold-start-tolerant
    // timeout and auto-retries with exponential backoff over a generous budget,
    // staying on the loading spinner; only a sustained failure surfaces the
    // error + Retry.
    if (mounted && (_error != null || _retrying)) {
      setState(() {
        _error = null;
        _retrying = false;
      });
    }
    try {
      final cat = await withColdStartRetry(
        () => widget.api.brainPreference(timeout: kColdStartCallTimeout),
        onRetry: () {
          if (mounted) setState(() => _retrying = true);
        },
      );
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _selected = cat.effectiveId;
      });
      widget.controller?._changed();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final brain = _selected;
    if (brain == null || brain.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.api.saveBrainPreference(brain);
      if (mounted) {
        AymaToast.show(context, 'Brain saved — starts on your next message.');
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
      // Shown only after the cold-start retry budget is spent (see [_load]);
      // Retry restarts the whole load sequence from scratch.
      return Column(
        key: const ValueKey('brain-selector-error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Could not load brains ($_error).',
              style: AymaType.sans(size: 13, color: AymaColors.error)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _load,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    if (_cat == null || _selected == null) {
      // GET /brain/preference (cold-start retries included) still in flight;
      // while a retry is pending/in flight the line says so instead of
      // holding the original line indefinitely.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: AymaWingLoader(
            size: 44,
            lines: _retrying
                ? AymaLoaderLines.reconnect
                : AymaLoaderLines.brains,
          ),
        ),
      );
    }
    final cat = _cat!;
    final shown = [for (final b in cat.brains) if (b.available) b];
    final selected = shown.any((b) => b.id == _selected)
        ? _selected
        : (shown.isNotEmpty ? shown.first.id : null);
    final current = shown.where((b) => b.id == selected);
    return Column(
      key: const ValueKey('brain-selector-control'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'BRAIN'),
        _dropdown(
          ac,
          value: selected,
          items: [
            for (final b in shown)
              DropdownMenuItem(
                value: b.id,
                child: Text(b.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: shown.isEmpty || _saving
              ? null
              : (v) {
                  setState(() => _selected = v);
                  widget.controller?._changed();
                },
        ),
        if (current.isNotEmpty && current.first.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              current.first.description,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ),
        if (widget.showSaveButton) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('brain-selector-save'),
              onPressed: _saving ? null : _save,
              // POST /brain/preference in flight — button slot, wings only.
              child: _saving
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : const Text('Save brain'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _label(AymaTokens ac, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.5)),
      );

  Widget _dropdown(
    AymaTokens ac, {
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?>? onChanged,
  }) {
    final effective = items.any((i) => i.value == value) ? value : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: ac.lineSoft),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<String>(
        key: const ValueKey('brain-dropdown'),
        value: effective,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: items,
        onChanged: _saving ? null : onChanged,
        style: AymaType.sans(size: 15, color: ac.fg),
      ),
    );
  }
}
