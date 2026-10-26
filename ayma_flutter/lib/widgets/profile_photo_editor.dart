import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/app_context.dart';
import '../services/photo_service.dart';
import '../theme.dart';
import 'ayma_photo.dart';
import 'ayma_toast.dart';
import 'overflow_guards.dart';

/// Add / remove / reorder the public profile photos (§8.3, §8.7 step 6),
/// shown as a bottom sheet over the user's own profile. Removal is a soft removal server-side — the `user_media` doc,
/// Storage file and face embedding all stay.
///
/// Photos picked together in one "Add photo" action are uploaded, then
/// added to the grid in a single batched call (§ appearance batching) —
/// picking several at once analyses them together as one Appearance update
/// instead of N separate runs. A successful add also re-queues the
/// reverse-image "is this you online?" scan (§ web photo search) over the
/// newly added photos — any hits now surface inline in the deep-dive Living
/// Report's own "Photos to confirm" section (§ founder: the old standalone
/// Photo candidates screen is deleted — see `deep_dive_report_screen.dart`).
class ProfilePhotoEditor extends StatefulWidget {
  const ProfilePhotoEditor({
    super.key,
    this.service,
    this.picker,
  });

  /// Opens the editor over [context]; completes when the sheet is dismissed.
  static Future<void> show(BuildContext context,
      {PhotoService? service, ImagePicker? picker}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      clipBehavior: Clip.antiAlias,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: ProfilePhotoEditor(service: service, picker: picker),
      ),
    );
  }

  /// Photos to add in one action, at most (mirrors the server's
  /// `POST /media/photos/batch` cap).
  static const maxBatch = 9;

  final PhotoService? service;
  final ImagePicker? picker;

  @override
  State<ProfilePhotoEditor> createState() => _ProfilePhotoEditorState();
}

class _ProfilePhotoEditorState extends State<ProfilePhotoEditor>
    with ScreenContextReasserter<ProfilePhotoEditor> {
  late final PhotoService _svc = widget.service ?? PhotoService();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  List<GridPhoto>? _photos;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    _load();
  }

  @override
  void reassertScreenContext() =>
      AppContext.instance.set(screen: 'photo_management');

  Future<void> _load() async {
    try {
      final p = await _svc.loadGrid();
      if (mounted) setState(() => _photos = p);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _add() async {
    if (_busy) return;
    final List<XFile> picked;
    try {
      picked = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 88);
    } catch (_) {
      _snack("Couldn't open your gallery — try again.",
          kind: AymaToastKind.error);
      return;
    }
    if (picked.isEmpty) return;
    var files = picked.map((x) => File(x.path)).toList();
    if (files.length > ProfilePhotoEditor.maxBatch) {
      _snack('You can add up to ${ProfilePhotoEditor.maxBatch} photos at '
          'once — using the first ${ProfilePhotoEditor.maxBatch}.',
              kind: AymaToastKind.warning);
      files = files.take(ProfilePhotoEditor.maxBatch).toList();
    }
    setState(() => _busy = true);
    try {
      final batch = await _svc.uploadAndProcessAll(files);
      if (batch.mediaIds.isNotEmpty) {
        final result = await _svc.addToGridBatch(batch.mediaIds);
        // Fire-and-forget: re-run the reverse-image "is this you?" search
        // over the photos that just landed, not just the onboarding set.
        unawaited(_svc.rescanWebSearchPhotos(batch.storagePaths)
            .catchError((_) {}));
        await _load();
        final failedCount = batch.rejected.length + result.failed.length;
        if (failedCount > 0) {
          _snack(failedCount == 1
              ? '1 photo could not be added.'
              : '$failedCount photos could not be added.',
                  kind: AymaToastKind.warning);
        }
      } else {
        _snack(batch.rejected.length == 1
            ? "That photo can't be used."
            : "Those photos can't be used.", kind: AymaToastKind.warning);
      }
    } catch (e) {
      _snack('Upload failed ($e).', kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(GridPhoto p) async {
    setState(() => _photos = [..._photos!]..removeWhere(
        (x) => x.mediaId == p.mediaId));
    try {
      await _svc.remove(p.mediaId);
    } catch (e) {
      _snack('Could not remove ($e).', kind: AymaToastKind.error);
      await _load();
    }
  }

  // `onReorderItem` (unlike the deprecated `onReorder`) already adjusts
  // newIndex for the item having been removed from oldIndex, so don't
  // decrement it again here.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = [..._photos!];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _photos = list);
    try {
      await _svc.reorder(list.map((p) => p.mediaId).toList());
    } catch (e) {
      _snack('Could not save order ($e).', kind: AymaToastKind.error);
      await _load();
    }
  }

  void _snack(String m, {AymaToastKind kind = AymaToastKind.info}) {
    if (mounted) AymaToast.show(context, m, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Your photos'),
        actions: [
          IconButton(
            tooltip: 'Done',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _add,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(
                    strokeWidth: 2))
            : const Icon(Icons.add_a_photo_outlined),
        label: const Text('Add photo'),
      ),
      body: _error != null
          ? CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load photos ($_error).',
                  style: AymaType.sans(size: 14, color: AymaColors.error)),
            )
          : _photos == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    if (_photos!.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'No photos yet. Add one to get started.',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(
                              size: 15, soft: true, color: ac.fgMute),
                        ),
                      )
                    else
                      ReorderableListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        onReorderItem: _reorder,
                        children: [
                          for (var i = 0; i < _photos!.length; i++)
                            _PhotoRow(
                              key: ValueKey(_photos![i].mediaId),
                              photo: _photos![i],
                              primary: i == 0,
                              onRemove: () => _remove(_photos![i]),
                            ),
                        ],
                      ),
                  ],
                ),
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({
    super.key,
    required this.photo,
    required this.primary,
    required this.onRemove,
  });

  final GridPhoto photo;
  final bool primary;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: AymaPhoto(
                url: photo.downloadUrl,
                displayWidth: 64,
                error: Container(
                  color: ac.bgCard,
                  child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              primary ? 'Primary photo' : 'Photo',
              style: AymaType.sans(size: 14, color: ac.fg),
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.delete_outline, color: ac.fgMute),
            onPressed: onRemove,
          ),
          Icon(Icons.drag_handle, color: ac.fgMute),
        ],
      ),
    );
  }
}

