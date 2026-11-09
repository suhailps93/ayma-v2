import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';
import 'picker_info_label.dart';

/// The **image model** picker (image-generation restore, 2026-11-08). Reads
/// `GET /image-model/preference` and lets the user choose which model Ayma uses
/// to generate and edit images in chat. Image generation is the ONE
/// founder-authorized direct-provider path (billed to the provider, not the
/// LiveKit credits); only configured providers come back, so Gemini-direct is
/// the default and the only entry until an xAI key is set.
///
/// This selection is its own per-user setting, independent of the Brain and the
/// voice stack. On the "Ayma's models" screen the screen owns the single save
/// button ([showSaveButton] false + an [ImageModelController]); standalone use
/// keeps its own save button and calls `POST /image-model/preference`.
class ImageModelSelectorControl extends StatefulWidget {
  const ImageModelSelectorControl({
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
  final ImageModelController? controller;
  final bool showSaveButton;

  /// Test seams for the live-update listener; default to the app globals.
  final FirebaseFirestore? firestore;
  final String? uid;

  @override
  State<ImageModelSelectorControl> createState() =>
      _ImageModelSelectorControlState();
}

/// Lets the Models screen read the current image-model selection and know when
/// the control has loaded, so ONE screen-level save persists every section.
class ImageModelController extends ChangeNotifier {
  _ImageModelSelectorControlState? _state;

  String? get selected => _state?._selected;
  bool get ready => _state?._cat != null && _state?._selected != null;

  void _attach(_ImageModelSelectorControlState s) => _state = s;
  void _detach(_ImageModelSelectorControlState s) {
    if (_state == s) _state = null;
  }

  void _changed() => notifyListeners();
}

class _ImageModelSelectorControlState extends State<ImageModelSelectorControl> {
  ImageModelCatalog? _cat;
  String? _selected;
  String? _error;
  bool _saving = false;
  bool _retrying = false;

  // Live update: when Ayma (or any surface) saves a new image model to
  // `ayma_image_model` on users/{uid}/profile/main, the open screen reflects it
  // at once instead of only on reopen.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  String? _watched;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _load();
    _listenForSaved();
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _profileSub?.cancel();
    super.dispose();
  }

  DocumentReference<Map<String, dynamic>>? _profileRef() {
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

  void _listenForSaved() {
    final ref = _profileRef();
    if (ref == null) return;
    try {
      _profileSub = ref.snapshots().listen(_onSnap, onError: (_) {});
    } catch (_) {
      // No live updates in this environment; initial _load still rendered.
    }
  }

  void _onSnap(DocumentSnapshot<Map<String, dynamic>> snap) {
    final v = (snap.data()?['ayma_image_model'] as String? ?? '').trim();
    if (_watched == null) {
      _watched = v;
      return;
    }
    if (v == _watched) return;
    _watched = v;
    if (!mounted || _saving || v.isEmpty) return;
    final cat = _cat;
    if (cat == null || !cat.models.any((m) => m.id == v)) return;
    setState(() => _selected = v);
    widget.controller?._changed();
  }

  Future<void> _load() async {
    if (mounted && (_error != null || _retrying)) {
      setState(() {
        _error = null;
        _retrying = false;
      });
    }
    try {
      final cat = await withColdStartRetry(
        () => widget.api.imageModelPreference(timeout: kColdStartCallTimeout),
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
    final model = _selected;
    if (model == null || model.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.api.saveImageModelPreference(model);
      if (mounted) {
        AymaToast.show(
            context, 'Image model saved — used on your next image.');
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
      return Column(
        key: const ValueKey('image-model-selector-error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Could not load image models ($_error).',
              style: AymaType.sans(size: 13, color: AymaColors.error)),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    if (_cat == null || _selected == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: AymaWingLoader(
            size: 44,
            lines: _retrying
                ? AymaLoaderLines.reconnect
                : AymaLoaderLines.generic,
          ),
        ),
      );
    }
    final cat = _cat!;
    final shown = [for (final m in cat.models) if (m.available) m];
    final selected = shown.any((m) => m.id == _selected)
        ? _selected
        : (shown.isNotEmpty ? shown.first.id : null);
    return Column(
      key: const ValueKey('image-model-selector-control'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PickerInfoLabel(
          label: 'IMAGE MODEL',
          infoKey: 'picker-info-image',
          title: 'Image model',
          explanation:
              'The model Ayma uses to create and edit images in chat. '
              'Gemini is the default. More models appear here as they '
              'are switched on.',
        ),
        _dropdown(
          ac,
          value: selected,
          items: [
            for (final m in shown)
              DropdownMenuItem(
                value: m.id,
                child: Text(m.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: shown.isEmpty || _saving
              ? null
              : (v) {
                  setState(() => _selected = v);
                  widget.controller?._changed();
                },
        ),
        if (widget.showSaveButton) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('image-model-selector-save'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : const Text('Save image model'),
            ),
          ),
        ],
      ],
    );
  }

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
        key: const ValueKey('image-model-dropdown'),
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
