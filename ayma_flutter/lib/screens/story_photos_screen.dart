import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'chat_screen.dart';

/// The full "photos Ayma has" gallery — every photo the user's account holds,
/// of any source (profile grid, chat, or the open web), grouped and with the
/// same actions the old Your Story screen had inline: view, delete
/// ("removed by you" — Ayma keeps it), make public, chat about it.
///
/// Your Story's document itself only ever shows a small mosaic *teaser*
/// (§ PhotosInterlude) — this screen is what "View all photos →" opens.
class StoryPhotosScreen extends StatefulWidget {
  const StoryPhotosScreen({super.key, this.api});

  static const path = '/profile/wiki/photos';

  final ApiClient? api;

  @override
  State<StoryPhotosScreen> createState() => _StoryPhotosScreenState();
}

class _StoryPhotosScreenState extends State<StoryPhotosScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _loading = true;
  List<AiNotePhoto> _photos = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final notes = await _api.aiNotes();
      if (mounted) setState(() => _photos = notes.photos);
    } catch (e) {
      debugPrint('[story photos] load failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _hidePhoto(AiNotePhoto p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.photoHide(p.url, source: p.source);
      await _load();
      _toast('Removed that photo');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishPhoto(AiNotePhoto p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.photoPublish(p.url, source: p.source);
      await _load();
      _toast('Added to your public profile');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPhoto(AiNotePhoto p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => PhotoDetailSheet(
        photo: p,
        onHide: () => _hidePhoto(p),
        onPublish: () => _publishPhoto(p),
        onChat: () => _openChatForPhoto(p),
      ),
    );
  }

  Future<void> _openChatForPhoto(AiNotePhoto p) async {
    Navigator.of(context).pop(); // close the photo detail sheet first
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.ac.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ChatScreen(apiClient: widget.api, photoUrl: p.url, photoSource: p.source),
      ),
    );
    if (mounted) await _load();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Photos')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _photos.isEmpty
              ? Center(
                  child: Text('No photos yet.',
                      style: AymaType.sans(size: 14, color: ac.fgMute)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    for (final (group, label) in photoGroups)
                      if (_photos.any((p) => displayGroup(p) == group)) ...[
                        Text(
                          '$label (${_photos.where((p) => displayGroup(p) == group).length})',
                          style: AymaType.mono(size: 10, color: ac.fgMute)
                              .copyWith(letterSpacing: 1.4),
                        ),
                        const SizedBox(height: 10),
                        PhotoGallery(
                          photos: _photos.where((p) => displayGroup(p) == group).toList(),
                          onOpen: _openPhoto,
                        ),
                        const SizedBox(height: 24),
                      ],
                  ],
                ),
    );
  }
}

/// One thumbnail's border colour, by where it came from.
Color photoEdgeColor(BuildContext context, AiNotePhoto p) {
  final ac = context.ac;
  if (p.deleted) return ac.error;
  return switch (p.source) {
    'profile' => ac.fg,
    'chat' => ac.fgMute,
    _ => ac.error, // web
  };
}

/// A photo's *display* group: a deleted photo always shows under "deleted",
/// regardless of where it actually came from.
String displayGroup(AiNotePhoto p) => p.deleted ? 'deleted' : p.source;

const photoGroups = [
  ('profile', 'PROFILE PHOTOS'),
  ('chat', 'FROM CHAT & SKILLS'),
  ('web', 'FOUND ON THE INTERNET'),
  ('deleted', 'DELETED BY YOU'),
];

/// A wrap of square thumbnails, edge-coloured by source; tapping one opens
/// the photo detail sheet.
class PhotoGallery extends StatelessWidget {
  const PhotoGallery({super.key, required this.photos, required this.onOpen});

  final List<AiNotePhoto> photos;
  final void Function(AiNotePhoto) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in photos)
          InkWell(
            onTap: () => onOpen(p),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: photoEdgeColor(context, p), width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.network(
                  p.url,
                  width: 92,
                  height: 92,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 92,
                    height: 92,
                    color: ac.bgElev,
                    child: Icon(Icons.broken_image_outlined, size: 20, color: ac.fgMute),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The photo detail sheet — the big image, Ayma's own read of it, and the
/// three actions: delete, make public, chat about it.
class PhotoDetailSheet extends StatefulWidget {
  const PhotoDetailSheet({
    super.key,
    required this.photo,
    required this.onHide,
    required this.onPublish,
    required this.onChat,
  });

  final AiNotePhoto photo;
  final Future<void> Function() onHide;
  final Future<void> Function() onPublish;
  final VoidCallback onChat;

  @override
  State<PhotoDetailSheet> createState() => _PhotoDetailSheetState();
}

class _PhotoDetailSheetState extends State<PhotoDetailSheet> {
  String? _acting;

  Future<void> _run(String which, Future<void> Function() action) async {
    if (_acting != null) return;
    setState(() => _acting = which);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _acting = null);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final p = widget.photo;
    final edge = photoEdgeColor(context, p);
    final label = switch (p.source) {
      'profile' => 'Public — on your profile',
      'chat' => 'Private — shared in chat',
      _ => 'AI only — Ayma found this online',
    };
    final isUserLabel = switch (p.isUser) {
      'yes' => 'Ayma thinks this is you',
      'no' => "Ayma doesn't think this is you",
      _ => "Ayma hasn't checked yet",
    };
    final busy = _acting != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => PhotoViewer(url: p.url),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.network(p.url, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color: ac.bgElev,
                          child: Icon(Icons.broken_image_outlined, color: ac.fgMute))),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: edge, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: AymaType.sans(size: 12, color: edge)),
            ]),
            if (p.sourcePage.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Found at ${p.sourcePage}',
                  style: AymaType.sans(size: 11, color: ac.fgMute),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 16),
            Text(isUserLabel, style: AymaType.sans(size: 13, color: ac.fgMute)),
            const SizedBox(height: 16),
            Text('What Ayma knows about this photo',
                style: AymaType.sans(size: 12, weight: FontWeight.w600, color: ac.fg)),
            const SizedBox(height: 6),
            Text(
              p.context.isNotEmpty
                  ? p.context
                  : "Ayma hasn't described this photo yet — ask her in chat.",
              style: AymaType.sans(size: 13, color: p.context.isNotEmpty ? ac.fg : ac.fgMute),
            ),
            const SizedBox(height: 20),
            if (busy)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(_acting == 'publish' ? 'Publishing…' : 'Deleting…',
                      style: AymaType.sans(size: 13, color: ac.fgMute)),
                ],
              )
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _run('hide', widget.onHide),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                ),
                if (!p.isProfile) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _run('publish', widget.onPublish),
                      icon: const Icon(Icons.public, size: 18),
                      label: const Text('Make public'),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.onChat,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('Chat about it'),
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

class PhotoViewer extends StatelessWidget {
  const PhotoViewer({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
