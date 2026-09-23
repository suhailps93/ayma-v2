import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/photo_gallery.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for the "reads the whole HD picture every time" bug: the
/// Story screen's PROFILE PHOTOS grid (and the other groups sharing this
/// widget) must decode+cache each thumbnail through [CachedNetworkImage] at
/// a size capped to its 92x92 on-screen footprint, not a plain
/// `Image.network` that always decodes the full original.
void main() {
  testWidgets('PhotoGallery thumbnails use CachedNetworkImage with a '
      'thumbnail-sized memCacheWidth, not a bare Image.network',
      (tester) async {
    const photo = AiNotePhoto(
      id: 'p1',
      url: 'https://example.invalid/photo.png',
      source: 'profile',
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: PhotoGallery(photos: const [photo], onOpen: (_) {}),
      ),
    ));
    await tester.pump();

    // The grid must render through the caching widget, not a plain
    // Image.network (CachedNetworkImage itself builds an Image internally,
    // so the check is for the wrapper, not the absence of any Image).
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(cached.imageUrl, photo.url);
    // A tight decode cap is the whole point of the fix — without it, the
    // widget still downloads and decodes the full original for a 92px tile.
    // AymaPhoto caps at displayWidth * devicePixelRatio, so allow generous
    // headroom for a high-DPR test device while still ruling out a
    // full-resolution (e.g. 3000px+) decode.
    expect(cached.memCacheWidth, isNotNull);
    expect(cached.memCacheWidth!, lessThanOrEqualTo(92 * 4));
  });
}
