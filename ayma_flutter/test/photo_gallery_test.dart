import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/node_visibility.dart';
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

  testWidgets(
      'PhotoGallery renders ALL images as ONE horizontal swipeable strip, '
      'never a static Wrap grid (Scout NOTE 256)', (tester) async {
    // Daniel fixture: 7 images in one section.
    final photos = [
      for (var i = 0; i < 7; i++)
        AiNotePhoto(
          id: 'p$i',
          url: 'https://example.invalid/photo$i.png',
          source: 'profile',
        ),
    ];

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: PhotoGallery(photos: photos, onOpen: (_) {}),
      ),
    ));
    await tester.pump();

    // The old non-swipeable grid (Wrap) is gone.
    expect(find.byType(Wrap), findsNothing);
    // One swipeable strip: a horizontally-scrolling ListView carrying every
    // image tile, so a DRAG scrolls through all of them.
    expect(find.byKey(const Key('photo_gallery_strip')), findsOneWidget);
    final lv = tester.widget<ListView>(find.byType(ListView));
    expect(lv.scrollDirection, Axis.horizontal);
    expect(
        tester.widget<Scrollable>(find.byType(Scrollable)).axisDirection,
        AxisDirection.right);
    // All seven tiles belong to the one strip.
    expect(find.byType(InkWell), findsNWidgets(7));
  });

  testWidgets('tapping a strip tile opens the owner photo-detail sheet',
      (tester) async {
    AiNotePhoto? opened;
    final photos = [
      const AiNotePhoto(
          id: 'p0', url: 'https://example.invalid/a.png', source: 'chat'),
      const AiNotePhoto(
          id: 'p1', url: 'https://example.invalid/b.png', source: 'chat'),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: PhotoGallery(photos: photos, onOpen: (p) => opened = p)),
    ));
    await tester.pump();
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(opened?.id, 'p0');
  });

  testWidgets(
      'PhotoDetailSheet image opens the fullscreen gallery (PageView) across '
      'the group when gallery urls are supplied (Scout NOTE 256)',
      (tester) async {
    const photo = AiNotePhoto(
        id: 'p1', url: 'https://example.invalid/p1.png', source: 'profile');
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: PhotoDetailSheet(
          photo: photo,
          onHide: () async {},
          onPublish: () async {},
          onMakePrivate: () async {},
          onChat: () {},
          galleryUrls: const [
            'https://example.invalid/p0.png',
            'https://example.invalid/p1.png',
            'https://example.invalid/p2.png',
          ],
          galleryIndex: 1,
        ),
      ),
    ));
    await tester.pump();
    // Tap the big image → the fullscreen gallery (a swipeable PageView) opens.
    await tester.tap(find.byType(AspectRatio));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('PhotoDetailSheet and PhotoViewer render the visible is-user note',
      (tester) async {
    const photo = AiNotePhoto(
      id: 'p1',
      url: 'https://example.invalid/photo.png',
      source: 'profile',
      isUser: 'yes',
      context: 'Selfie at the park',
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: PhotoDetailSheet(
          photo: photo,
          onHide: () async {},
          onPublish: () async {},
          onMakePrivate: () async {},
          onChat: () {},
        ),
      ),
    ));
    await tester.pump();

    // The detail sheet displays the verdict note
    expect(find.text('Ayma thinks this is you'), findsOneWidget);

    // PhotoViewer dialog renders the visible note overlay
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PhotoViewer(
          url: 'https://example.invalid/photo.png',
          isUser: 'yes',
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Ayma thinks this is you'), findsOneWidget);
  });

  // --- Ayma-only (retained) photo: label + AI-only colour (retention rule) ---
  testWidgets('PhotoDetailSheet Ayma-only photo reads as kept-by-Ayma in the '
      'AI-only colour', (tester) async {
    const photo = AiNotePhoto(
      id: 'p1',
      url: 'https://example.invalid/photo.png',
      source: 'web',
      visibility: 'ayma_only',
    );

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: PhotoDetailSheet(
          photo: photo,
          onHide: () async {},
          onPublish: () async {},
          onMakePrivate: () async {},
          onChat: () {},
        ),
      ),
    ));
    await tester.pump();

    final labelFinder =
        find.text('Ayma-only — kept by Ayma, not on your profile');
    expect(labelFinder, findsOneWidget);
    final style = tester.widget<Text>(labelFinder).style!;
    // An Ayma-only photo takes the AI-only visibility colour, overriding its
    // source colour (never the raw error red).
    expect(style.color, nodeVisibilityColor('ayma_only'));
  });

  // --- NOTE 250 item 2 + 4: delete confirms, verdict + Make-private read the node ---
  Widget sheet(AiNotePhoto photo,
          {Future<void> Function()? onHide,
          Future<void> Function()? onMakePrivate}) =>
      MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          body: PhotoDetailSheet(
            photo: photo,
            onHide: onHide ?? () async {},
            onPublish: () async {},
            onMakePrivate: onMakePrivate ?? () async {},
            onChat: () {},
          ),
        ),
      );

  testWidgets('Delete asks for confirmation before removing the photo node',
      (tester) async {
    var hidden = false;
    const photo = AiNotePhoto(
        id: 'p1', url: 'https://example.invalid/p.png', source: 'chat');
    await tester.pumpWidget(sheet(photo, onHide: () async => hidden = true));
    await tester.pump();

    await tester.ensureVisible(find.byKey(const Key('photo_delete')));
    await tester.tap(find.byKey(const Key('photo_delete')));
    await tester.pumpAndSettle();
    // A confirmation dialog appears; nothing deleted yet. The copy is truthful
    // to retention (Scout NOTE 256): removes from story/profile, Ayma keeps a
    // copy — NOT the old "removes it everywhere".
    expect(
        find.text('This removes it from your story and profile. Ayma keeps '
            'its own copy in your Photos.'),
        findsOneWidget);
    expect(hidden, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(hidden, isTrue);
  });

  testWidgets(
      'a public node offers Make private (not Make public) and flips in place',
      (tester) async {
    var madePrivate = false;
    const photo = AiNotePhoto(
        id: 'p1', url: 'https://example.invalid/p.png', source: 'profile',
        visibility: 'public');
    await tester
        .pumpWidget(sheet(photo, onMakePrivate: () async => madePrivate = true));
    await tester.pump();

    expect(find.text('Public — on your profile'), findsOneWidget);
    expect(find.byKey(const Key('photo_make_private')), findsOneWidget);
    expect(find.byKey(const Key('photo_make_public')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('photo_make_private')));
    await tester.tap(find.byKey(const Key('photo_make_private')));
    await tester.pumpAndSettle();
    expect(madePrivate, isTrue);
    // The label + button now read the node's new (private) state, in place.
    expect(find.text('Private — only you and Ayma'), findsOneWidget);
    expect(find.byKey(const Key('photo_make_public')), findsOneWidget);
  });

  testWidgets(
      'is_you unknown WITH a read says Ayma read it, never "hasn\'t checked"',
      (tester) async {
    const withRead = AiNotePhoto(
        id: 'p1', url: 'https://example.invalid/p.png', source: 'chat',
        isUser: '', context: 'A dog in a park');
    await tester.pumpWidget(sheet(withRead));
    await tester.pump();
    expect(find.text("Ayma read this but couldn't confirm it's you"),
        findsOneWidget);
    expect(find.text("Ayma hasn't checked yet"), findsNothing);

    const noRead = AiNotePhoto(
        id: 'p2', url: 'https://example.invalid/p.png', source: 'chat',
        isUser: '', context: '');
    await tester.pumpWidget(sheet(noRead));
    await tester.pump();
    expect(find.text("Ayma hasn't checked yet"), findsOneWidget);
  });
}
