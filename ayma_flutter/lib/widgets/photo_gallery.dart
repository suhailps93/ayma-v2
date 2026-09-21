import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'ask_ayma_action.dart';

/// Shared photo-gallery pieces used by Your Story's inline Photos section
/// (see `story_editor_screen.dart`) and by the appearance report screen's
/// full-screen zoom ([PhotoViewer]). Previously lived in the now-removed
/// `story_photos_screen.dart` (a dedicated "view all photos" screen) — kept
/// here so the grid/detail/zoom rendering isn't duplicated.

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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't update that photo — try again.")),
        );
      }
      return;
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
      child: SingleChildScrollView(
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
                  child: AskAymaAction(
                    label: 'Chat about it',
                    onPressed: widget.onChat,
                  ),
                ),
              ]),
          ],
        ),
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
