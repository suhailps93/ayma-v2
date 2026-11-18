import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'ask_ayma_action.dart';
import 'ayma_photo.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';
import 'node_visibility.dart';

/// Shared photo-gallery pieces used by Your Story's inline Photos section
/// (see `story_editor_screen.dart`) and by the appearance report screen's
/// full-screen zoom ([PhotoViewer]). Previously lived in the now-removed
/// `story_photos_screen.dart` (a dedicated "view all photos" screen) — kept
/// here so the grid/detail/zoom rendering isn't duplicated.

/// One thumbnail's border colour, by where it came from — an Ayma-only
/// (retained / AI-only) photo takes the AI-only colour, overriding its source.
Color photoEdgeColor(BuildContext context, AiNotePhoto p) {
  final ac = context.ac;
  if (p.visibility == 'ayma_only') return nodeVisibilityColor('ayma_only');
  return switch (p.source) {
    'profile' => ac.fg,
    'chat' => ac.fgMute,
    _ => ac.error, // web
  };
}

/// A photo's *display* group: an Ayma-only photo (a deleted-but-retained image,
/// or a web find Ayma kept privately) always shows under the "ayma_only" group
/// — never on the user's profile/story surfaces — regardless of its source
/// (founder retention rule Nov 18 2026).
String displayGroup(AiNotePhoto p) =>
    p.visibility == 'ayma_only' ? 'ayma_only' : p.source;

const photoGroups = [
  ('profile', 'PROFILE PHOTOS'),
  ('chat', 'FROM CHAT & SKILLS'),
  ('web', 'FOUND ON THE INTERNET'),
  ('ayma_only', 'AYMA-ONLY — KEPT, NOT ON YOUR PROFILE'),
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
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: photoEdgeColor(context, p), width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 92,
                  height: 92,
                  child: AymaPhoto(
                    url: p.url,
                    displayWidth: 92,
                    error: Container(
                      color: ac.bgElev,
                      child: Icon(Icons.broken_image_outlined, size: 20, color: ac.fgMute),
                    ),
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
    required this.onMakePrivate,
    required this.onChat,
  });

  final AiNotePhoto photo;
  final Future<void> Function() onHide;
  final Future<void> Function() onPublish;

  /// Flip a public image node back to private (NOTE 250 item 4). Keyed by the
  /// image NODE, like [onPublish].
  final Future<void> Function() onMakePrivate;
  final VoidCallback onChat;

  @override
  State<PhotoDetailSheet> createState() => _PhotoDetailSheetState();
}

class _PhotoDetailSheetState extends State<PhotoDetailSheet> {
  String? _acting;

  /// The image NODE's own visibility, updated in place on a flip so the label
  /// + the Make public/private button read the node, never the stale snapshot
  /// or the parent fact's source (NOTE 250 item 4).
  late String _visibility = widget.photo.visibility;

  /// [newVisibility] non-null = a visibility flip: reflect it in place and keep
  /// the sheet open (so the label updates); null = a terminal action (delete),
  /// which pops.
  Future<void> _run(
    String which,
    Future<void> Function() action, {
    String? newVisibility,
  }) async {
    if (_acting != null) return;
    setState(() => _acting = which);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        AymaToast.show(context, "Couldn't update that photo — try again.",
            kind: AymaToastKind.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _acting = null);
    }
    if (!mounted) return;
    if (newVisibility != null) {
      setState(() => _visibility = newVisibility);
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Delete must ALWAYS confirm first — a photo image node must never be
  /// removed by a single tap (NOTE 250 item 2, founder order Nov 15).
  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete photo'),
        content: const Text('Delete this photo? This removes it everywhere.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _run('hide', widget.onHide);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final p = widget.photo;
    final edge = photoEdgeColor(context, p);
    // The visibility label reads the image NODE's own visibility (updated in
    // place on a flip), not the ingestion source — a chat photo made public
    // must read "Public", never a stale "Private — shared in chat" (item 4).
    final label = switch (_visibility) {
      'public' => 'Public — on your profile',
      'ayma_only' => 'Ayma-only — kept by Ayma, not on your profile',
      _ => 'Private — only you and Ayma',
    };
    // The verdict matches the node state: is_you unknown with a real read means
    // Ayma DID look and couldn't confirm identity — never "hasn't checked yet"
    // (NOTE 250 item 4). "hasn't checked" only when there is no read at all.
    final isUserLabel = switch (p.isUser) {
      'yes' => 'Ayma thinks this is you',
      'no' => "Ayma doesn't think this is you",
      _ => p.context.isNotEmpty
          ? "Ayma read this but couldn't confirm it's you"
          : "Ayma hasn't checked yet",
    };
    final isPublic = _visibility == 'public';
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
                builder: (_) => PhotoViewer(url: p.url, isUser: p.isUser),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: AymaPhoto(
                    url: p.url,
                    displayWidth: 400,
                    error: Container(
                        color: ac.bgElev,
                        child: Icon(Icons.broken_image_outlined, color: ac.fgMute)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: edge, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(label,
                  style: AymaType.sans(
                      size: 12,
                      color: edge == ac.error ? ac.errorTextCard : edge)),
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
            const SizedBox(height: 8),
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
                  const AymaWingLoader(size: 16, showLabel: false),
                  const SizedBox(width: 8),
                  Text(_acting == 'hide' ? 'Deleting…' : 'Updating…',
                      style: AymaType.sans(size: 13, color: ac.fgMute)),
                ],
              )
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('photo_delete'),
                    onPressed: _confirmDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                ),
                const SizedBox(width: 8),
                // Reads the NODE's current visibility: Make private when public,
                // Make public otherwise (NOTE 250 item 4).
                Expanded(
                  child: isPublic
                      ? OutlinedButton.icon(
                          key: const Key('photo_make_private'),
                          onPressed: () => _run('private', widget.onMakePrivate,
                              newVisibility: 'private'),
                          icon: const Icon(Icons.lock_outline, size: 18),
                          label: const Text('Make private'),
                        )
                      : OutlinedButton.icon(
                          key: const Key('photo_make_public'),
                          onPressed: () => _run('publish', widget.onPublish,
                              newVisibility: 'public'),
                          icon: const Icon(Icons.public, size: 18),
                          label: const Text('Make public'),
                        ),
                ),
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
  const PhotoViewer({
    super.key,
    required this.url,
    this.isUser = '',
    this.caption = '',
    this.source = '',
  });

  final String url;

  /// The face-match verdict ("yes"/"no"/"unknown"/"").
  final String isUser;

  /// Ayma's read of the photo (the image node's `image_read`).
  final String caption;

  /// Where the photo came from (the image node's source provenance label).
  final String source;

  @override
  Widget build(BuildContext context) {
    // Node-driven overlay (founder Nov 16): the is-you verdict, the source, and
    // Ayma's read — all shown together, each from the image node.
    final verdict = switch (isUser) {
      'yes' => 'Ayma thinks this is you',
      'no' => "Ayma doesn't think this is you",
      _ => '',
    };
    final note = [
      if (verdict.isNotEmpty) verdict,
      if (source.isNotEmpty) source,
      if (caption.isNotEmpty) caption,
    ].join('\n');
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
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
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (note.isNotEmpty)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Text(
                    note,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
