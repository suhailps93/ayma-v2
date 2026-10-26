import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/photo_service.dart';
import '../theme.dart';
import 'ayma_photo.dart';

/// Drives inline photo management on the "My public profile" carousel (§8.3):
/// add, remove-from-public (with a deferred, undoable commit), set-primary,
/// drag-reorder and permanent delete. Holds the live [GridPhoto] list the
/// carousel renders, so edits show instantly (optimistic) and the backend is
/// reconciled behind them.
///
/// This replaced the old "Your photos" bottom-sheet editor — every capability
/// it had now lives here, wired straight into the carousel.
class InlinePhotoController extends ChangeNotifier {
  InlinePhotoController({PhotoService? service, ImagePicker? picker})
      : _svc = service ?? PhotoService(),
        _picker = picker ?? ImagePicker();

  final PhotoService _svc;
  final ImagePicker _picker;

  /// Photos to add in one action, at most (mirrors the server's
  /// `POST /media/photos/batch` cap).
  static const maxBatch = 9;

  /// How long a removed photo stays undoable before the backend removal is
  /// committed — matches [AymaToast]'s 5 s action window.
  static const undoWindow = Duration(seconds: 5);

  List<GridPhoto> _photos = const [];
  List<GridPhoto> get photos => _photos;

  bool _loading = true;
  bool get loading => _loading;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  /// Raised by a background commit (a deferred removal, a reorder/primary
  /// write) so the hosting screen can toast it. Not used for the initial load
  /// error, which [error] carries instead.
  void Function(String message)? onCommitError;

  // --- deferred, undoable removal ------------------------------------------
  GridPhoto? _pendingRemoval;
  int? _pendingIndex;
  Timer? _pendingTimer;

  /// True while a removed photo is still undoable.
  bool get hasPendingRemoval => _pendingRemoval != null;

  @override
  void dispose() {
    // Honour an in-flight removal so leaving the screen doesn't silently
    // resurrect a photo the user removed.
    unawaited(_commitPendingRemoval());
    _pendingTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final p = await _svc.loadGrid();
      _photos = p;
      _error = null;
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Pick photos from the gallery and add them to the public grid. Returns a
  /// short status message to toast (how many failed, empty string = nothing to
  /// say), or null if the user cancelled the picker.
  Future<String?> pickAndAdd() async {
    if (_busy) return null;
    await _commitPendingRemoval();
    final List<XFile> picked;
    try {
      picked = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 88);
    } catch (_) {
      return "Couldn't open your gallery — try again.";
    }
    if (picked.isEmpty) return null;
    var files = picked.map((x) => File(x.path)).toList();
    var note = '';
    if (files.length > maxBatch) {
      note = 'You can add up to $maxBatch photos at once — using the first '
          '$maxBatch.';
      files = files.take(maxBatch).toList();
    }
    _busy = true;
    notifyListeners();
    try {
      final batch = await _svc.uploadAndProcessAll(files);
      if (batch.mediaIds.isNotEmpty) {
        final result = await _svc.addToGridBatch(batch.mediaIds);
        unawaited(
            _svc.rescanWebSearchPhotos(batch.storagePaths).catchError((_) {}));
        await load();
        final failed = batch.rejected.length + result.failed.length;
        if (failed > 0) {
          return failed == 1
              ? '1 photo could not be added.'
              : '$failed photos could not be added.';
        }
        return note;
      }
      return batch.rejected.length == 1
          ? "That photo can't be used."
          : "Those photos can't be used.";
    } catch (e) {
      return 'Upload failed ($e).';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Remove a photo from the public profile, optimistically. The backend write
  /// is deferred for [undoWindow] so [undoRemove] can take it back with no
  /// round-trip. The caller must first check [photos] has more than one photo
  /// (a public profile needs at least one — see the last-photo guard).
  void removeFromPublic(GridPhoto photo) {
    // Flush any earlier pending removal before starting a new one.
    unawaited(_commitPendingRemoval());
    final idx = _photos.indexWhere((p) => p.mediaId == photo.mediaId);
    if (idx < 0) return;
    _pendingRemoval = photo;
    _pendingIndex = idx;
    _photos = [..._photos]..removeAt(idx);
    notifyListeners();
    _pendingTimer = Timer(undoWindow, () => unawaited(_commitPendingRemoval()));
  }

  /// Put back the most recently removed photo, if it is still undoable.
  void undoRemove() {
    final photo = _pendingRemoval;
    final idx = _pendingIndex;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingRemoval = null;
    _pendingIndex = null;
    if (photo == null || idx == null) return;
    final list = [..._photos];
    list.insert(idx.clamp(0, list.length), photo);
    _photos = list;
    notifyListeners();
  }

  Future<void> _commitPendingRemoval() async {
    final photo = _pendingRemoval;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingRemoval = null;
    _pendingIndex = null;
    if (photo == null) return;
    try {
      await _svc.remove(photo.mediaId);
    } catch (_) {
      onCommitError?.call('Could not remove that photo.');
      await load();
    }
  }

  /// Make [photo] the primary (hero) photo, optimistically.
  Future<void> setPrimary(GridPhoto photo) async {
    await _commitPendingRemoval();
    final idx = _photos.indexWhere((p) => p.mediaId == photo.mediaId);
    if (idx <= 0) return; // already primary, or not present
    final list = [..._photos];
    final moved = list.removeAt(idx);
    list.insert(0, moved);
    _photos = list;
    notifyListeners();
    try {
      await _svc.setPrimary(photo.mediaId);
    } catch (_) {
      onCommitError?.call('Could not set the primary photo.');
      await load();
    }
  }

  /// Drag-reorder; [oldIndex]/[newIndex] come from
  /// `ReorderableListView.onReorderItem`, which already adjusts [newIndex] for
  /// the item having left [oldIndex] (so no off-by-one correction here).
  Future<void> reorder(int oldIndex, int newIndex) async {
    await _commitPendingRemoval();
    if (oldIndex == newIndex) return;
    final list = [..._photos];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    _photos = list;
    notifyListeners();
    try {
      await _svc.reorder(list.map((p) => p.mediaId).toList());
    } catch (_) {
      onCommitError?.call('Could not save the new order.');
      await load();
    }
  }

  /// Delete a photo everywhere — erases the media and its analysis. Not
  /// reversible. Returns true on success.
  Future<bool> deletePermanent(GridPhoto photo) async {
    await _commitPendingRemoval();
    _photos = [..._photos]..removeWhere((p) => p.mediaId == photo.mediaId);
    notifyListeners();
    try {
      await _svc.deletePermanent(photo.mediaId);
      return true;
    } catch (_) {
      onCommitError?.call('Could not delete that photo.');
      await load();
      return false;
    }
  }
}

/// Bundles the [InlinePhotoController] with the screen-level handlers that
/// need a [BuildContext] (toasts, the last-photo guard, the delete-everywhere
/// confirm) so [ProfilePhotoHeader] can offer inline editing without owning
/// any of that UI. Non-null on the owner's own "My public profile" only;
/// every other profile view leaves it null and stays read-only.
class InlinePhotoEditing {
  const InlinePhotoEditing({
    required this.controller,
    required this.onAddPhoto,
    required this.onSetPrimary,
    required this.onRemove,
  });

  final InlinePhotoController controller;
  final VoidCallback onAddPhoto;
  final void Function(GridPhoto) onSetPrimary;
  final void Function(GridPhoto) onRemove;
}

/// The editable thumbnail strip under the hero on "My public profile" — the
/// inline replacement for the old "Your photos" bottom sheet. Each thumbnail
/// carries a star (primary — filled on the current primary, outline on the
/// rest) and a delete control; the strip long-press drag-reorders, and the
/// last tile is "Add photo". Tapping a thumbnail body selects it in the hero
/// above (via [onSelect]).
class InlinePhotoStrip extends StatelessWidget {
  const InlinePhotoStrip({
    super.key,
    required this.photos,
    required this.fallback,
    required this.currentPage,
    required this.busy,
    required this.onSelect,
    required this.onAddPhoto,
    required this.onSetPrimary,
    required this.onRemove,
    required this.onReorder,
  });

  /// Download URLs in grid order, index 0 = primary. Same list the hero shows.
  final List<String> photos;
  final Widget fallback;
  final int currentPage;
  final bool busy;
  final ValueChanged<int> onSelect;
  final VoidCallback onAddPhoto;
  final ValueChanged<int> onSetPrimary;
  final ValueChanged<int> onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  static const _thumb = 66.0;
  // Clears the two corner control chips that overhang the thumbnail top.
  static const _stripHeight = _thumb + 12;

  @override
  Widget build(BuildContext context) {
    final accent = context.ac.accent;
    final addTile = _AddTile(
      key: const ValueKey('inlinePhotoAddTile'),
      size: _thumb,
      busy: busy,
      onTap: busy ? null : onAddPhoto,
    );
    return ColoredBox(
      color: AymaColors.darkBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: SizedBox(
          height: _stripHeight,
          // With no photos yet there's nothing to reorder — show just the add
          // tile (a 0-item ReorderableListView is avoided).
          child: photos.isEmpty
              ? Align(alignment: Alignment.centerLeft, child: addTile)
              : ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: true,
                  itemCount: photos.length,
                  onReorderItem: onReorder,
                  proxyDecorator: (child, _, __) => child,
                  footer: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: addTile,
                  ),
                  itemBuilder: (context, i) {
                    return Padding(
                      key: ValueKey('inlinePhoto_$i'),
                      padding: const EdgeInsets.only(right: 8),
                      child: _EditableThumb(
                        size: _thumb,
                        url: photos[i],
                        fallback: fallback,
                        selected: i == currentPage,
                        primary: i == 0,
                        accent: accent,
                        onTap: () => onSelect(i),
                        onStar: () => onSetPrimary(i),
                        onDelete: () => onRemove(i),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _EditableThumb extends StatelessWidget {
  const _EditableThumb({
    required this.size,
    required this.url,
    required this.fallback,
    required this.selected,
    required this.primary,
    required this.accent,
    required this.onTap,
    required this.onStar,
    required this.onDelete,
  });

  final double size;
  final String url;
  final Widget fallback;
  final bool selected;
  final bool primary;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onStar;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Overflow headroom above the thumbnail for the corner chips.
    return SizedBox(
      width: size,
      height: size + 12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: size,
                height: size,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: AymaPhoto(
                    url: url,
                    displayWidth: 140,
                    error: fallback,
                  ),
                ),
              ),
            ),
          ),
          // Primary star — top-left. Filled on the primary photo, outline on
          // the rest; tap promotes this photo to primary.
          Positioned(
            top: 0,
            left: 0,
            child: _Chip(
              tooltip: primary ? 'Primary photo' : 'Make primary',
              icon: primary ? Icons.star_rounded : Icons.star_outline_rounded,
              iconColor: primary ? accent : Colors.white,
              onTap: onStar,
            ),
          ),
          // Remove-from-public — top-right.
          Positioned(
            top: 0,
            right: 0,
            child: _Chip(
              tooltip: 'Remove from public profile',
              icon: Icons.close_rounded,
              iconColor: Colors.white,
              onTap: onDelete,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small circular control chip overlaid on a thumbnail corner.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.tooltip,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 15, color: iconColor),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({super.key, required this.size, required this.busy, this.onTap});

  final double size;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = context.ac.accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white38, width: 1.5),
          color: Colors.white.withValues(alpha: 0.06),
        ),
        alignment: Alignment.center,
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.add_a_photo_outlined, color: accent, size: 24),
      ),
    );
  }
}
