// 2o P4 — the profile photo carousel is rebuilt to render each page through
// the ONE shared Node-Visualiser image-node renderer ([NodeImage]) instead of
// a bespoke raw AymaPhoto, deleting the second image renderer. This pins the
// founder's exact paths: the carousel renders image nodes, and "show the Nth
// picture" (the PhotoCarouselRegistry hook both voice and chat drive) still
// lands on the right photo through the real PageView.
import 'package:ayma_flutter/screens/public_profile_screen.dart'
    show ProfilePhotoHeader;
import 'package:ayma_flutter/services/photo_carousel_registry.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _photos = [
  'https://example.com/p1.jpg',
  'https://example.com/p2.jpg',
  'https://example.com/p3.jpg',
];

Future<void> _pumpHeader(WidgetTester tester) async {
  PhotoCarouselRegistry.instance.clear();
  addTearDown(PhotoCarouselRegistry.instance.clear);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfilePhotoHeader(
            photos: _photos,
            seed: 'her',
            name: 'Dana',
            age: 30,
            location: 'Berlin',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the carousel renders its photos as Node-Visualiser image nodes',
      (tester) async {
    await _pumpHeader(tester);

    // The hero page is a NodeImage (the shared image-node renderer), not a
    // bespoke carousel widget. PageView builds lazily, so the current page is
    // mounted; its node-image key is the carousel page id.
    expect(find.byType(NodeImage), findsWidgets);
    expect(find.byKey(const Key('node_image_carousel_0')), findsOneWidget);
  });

  testWidgets('"show the third picture" lands the carousel on photo 3',
      (tester) async {
    await _pumpHeader(tester);

    final registry = PhotoCarouselRegistry.instance;
    expect(registry.hasCarousel, isTrue);
    expect(registry.active!.photoCount(), 3);
    expect(registry.active!.currentPage(), 0);

    final out = registry.perform(op: 'goto', index: 3);
    expect(out.ok, isTrue);
    await tester.pumpAndSettle();
    expect(registry.active!.currentPage(), 2);
    // The newly-shown page is the shared image-node renderer too.
    expect(find.byKey(const Key('node_image_carousel_2')), findsOneWidget);

    // Out of range through the real widget: no move, honest real count.
    final miss = registry.perform(op: 'goto', index: 5);
    expect(miss.ok, isFalse);
    expect(miss.photoCount, 3);
    await tester.pumpAndSettle();
    expect(registry.active!.currentPage(), 2);
  });
}
