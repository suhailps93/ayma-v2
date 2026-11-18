/// The ONE photo-carousel renderer for the report framework (unified visual
/// report framework, founder Nov 17). Consecutive IMAGE leaf nodes on a report
/// surface aggregate into one swipeable square [PageView] of the shared
/// [NodeImage] `fill` renderer — the look the bespoke appearance report used to
/// own, now driven generically by the `photo_carousel` palette entry so EVERY
/// report's photos (appearance, web-research candidates-confirmed, any future
/// report) render the same way with zero per-report code.
///
/// Degrades safely: no images → renders nothing (the caller never builds it for
/// an empty group); one image → a single page with no dots; an undecodable URL
/// falls back to [NodeImage]'s own error painter. Never overflows at phone size
/// (the square AspectRatio + capped caption).
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../theme.dart';
import 'image_viewer.dart';
import 'node_visualiser.dart';

class NodePhotoCarousel extends StatefulWidget {
  const NodePhotoCarousel({super.key, required this.images});

  /// The image nodes to page through (expected non-empty, each [StoryNode.isImage]).
  final List<StoryNode> images;

  @override
  State<NodePhotoCarousel> createState() => _NodePhotoCarouselState();
}

class _NodePhotoCarouselState extends State<NodePhotoCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFullscreen(int index) async {
    final urls = [
      for (final n in widget.images)
        if (n.imageUrl.isNotEmpty) n.imageUrl,
    ];
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
    final images = widget.images;
    if (images.isEmpty) return const SizedBox.shrink();
    final page = _page.clamp(0, images.length - 1);
    final caption = images[page].imageRead;
    return Column(
      key: const Key('node_photo_carousel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1,
            child: PageView.builder(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: images.length,
              itemBuilder: (_, i) => NodeImage(
                key: Key('node_carousel_photo_$i'),
                node: images[i],
                fill: true,
                displayWidth: 800,
                onTap: () => _openFullscreen(i),
              ),
            ),
          ),
        ),
        if (images.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < images.length; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == page ? ac.accent : ac.lineSoft,
                    ),
                  ),
              ],
            ),
          ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              caption,
              style: AymaType.sans(size: 12.5, height: 1.35, color: ac.fgMute),
            ),
          ),
      ],
    );
  }
}
