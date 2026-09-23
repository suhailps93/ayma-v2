import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/app_context.dart';
import '../services/photo_service.dart';
import '../theme.dart';

/// Add / remove / reorder profile photos, and connect Instagram (§8.3, §8.7
/// step 6). Removal is a soft removal server-side — the `user_media` doc,
/// Storage file and face embedding all stay.
class PhotoManagementScreen extends StatefulWidget {
  const PhotoManagementScreen({super.key, this.service, this.picker});

  static const path = '/settings/photos';

  final PhotoService? service;
  final ImagePicker? picker;

  @override
  State<PhotoManagementScreen> createState() => _PhotoManagementScreenState();
}

class _PhotoManagementScreenState extends State<PhotoManagementScreen>
    with ScreenContextReasserter<PhotoManagementScreen> {
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
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final media = await _svc.uploadAndProcess(File(picked.path));
      if (!media.published) {
        _snack(media.reason.isEmpty
            ? "That photo can't be used."
            : "That photo can't be used: ${media.reason}");
      } else {
        await _svc.addToGrid(media.mediaId);
        await _load();
      }
    } catch (e) {
      _snack('Upload failed ($e).');
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
      _snack('Could not remove ($e).');
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
      _snack('Could not save order ($e).');
      await _load();
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Photos')),
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load photos ($_error).',
                    style: AymaType.sans(size: 14, color: AymaColors.error)),
              ),
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
            child: Image.network(
              photo.downloadUrl,
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 64,
                height: 64,
                color: ac.bgCard,
                child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
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
