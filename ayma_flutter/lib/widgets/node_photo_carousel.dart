/// The ONE photo-carousel renderer for the report framework (unified visual
/// report framework, founder Nov 17). EVERY image leaf of a report section
/// aggregates into this ONE swipeable carousel (appearance, web-research
/// candidates-confirmed, any future report) so a report's photos render as a
/// single strip of real photos with zero per-report code.
///
/// Shape (Scout NOTE 255 — "settle it as a swipeable carousel"):
///  - the inline strip is a horizontal, swipeable [ListView] of square photo
///    tiles — it SCROLLS through ALL of the section's images, not a static grid
///    and not a one-per-screen page that can't tell it has neighbours;
///  - tapping any tile opens the fullscreen DETAIL (`AymaImageViewer.gallery`),
///    a [PageView] across the same images that ADVANCES ON SWIPE.
///
/// Degrades safely: no images → renders nothing (the caller never builds it for
/// an empty group); one image → a single tile; an undecodable URL falls back to
/// [NodeImage]'s own error painter. Never overflows at phone size — the strip is
/// horizontally scrollable, its height follows the viewer's text scale, and each
/// caption is capped to two ellipsised lines.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../theme.dart';
import 'image_viewer.dart';
import 'node_visualiser.dart';

class NodePhotoCarousel extends StatelessWidget {
  const NodePhotoCarousel({super.key, required this.images});

  /// The image nodes to page through (expected non-empty, each
  /// [StoryNode.isImage]). ALREADY viewer-filtered by the caller, so a
  /// private / Ayma-only photo never reaches a surface it may not show.
  final List<StoryNode> images;

  /// The square photo tile edge, in logical pixels.
  static const double _tile = 150;

  Future<void> _openDetail(
      BuildContext context, int index, List<StoryNode> shown) async {
    final urls = [for (final n in shown) n.imageUrl];
    if (urls.isEmpty) return;
    await AymaImageViewer.openGallery(
      context,
      urls: urls,
      initialIndex: index.clamp(0, urls.length - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Guard against an empty-URL node slipping in (the caller builds this only
    // for `isImage` nodes, but stay defensive).
    final shown = [
      for (final n in images)
        if (n.imageUrl.isNotEmpty) n,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();

    // Bound the horizontal strip's height to the tile plus a two-line caption
    // block sized for the viewer's text scale, so a large accessibility scale
    // never overflows the fixed cross-axis height.
    final scaler = MediaQuery.textScalerOf(context);
    final captionLine = scaler.scale(12.5) * 1.4;
    // tile + a two-line caption block + top gap + a few px of slack so the
    // per-tile Column never overflows its fixed cross-axis height (the layout
    // matrix treats a 1px RenderFlex overflow as a failure).
    final stripHeight = _tile + 8 + (captionLine * 2).ceilToDouble() + 4;

    return SizedBox(
      key: const Key('node_photo_carousel'),
      height: stripHeight,
      child: ListView.separated(
        key: const Key('node_carousel_strip'),
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final node = shown[i];
          final caption = node.imageRead;
          return SizedBox(
            width: _tile,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: _tile,
                    height: _tile,
                    child: NodeImage(
                      key: Key('node_carousel_photo_$i'),
                      node: node,
                      fill: true,
                      displayWidth: 400,
                      onTap: () => _openDetail(context, i, shown),
                    ),
                  ),
                ),
                if (caption.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          AymaType.sans(size: 12.5, height: 1.4, color: ac.fgMute),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
