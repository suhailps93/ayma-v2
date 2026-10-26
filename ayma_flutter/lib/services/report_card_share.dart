import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import 'gallery_saver.dart';

/// Where the Share sheet can send the report card image.
enum CardShareTarget { whatsapp, instagram, save, more }

/// Turns the Appearance report card into a 1080x1920 PNG on the device and
/// hands it to WhatsApp, Instagram, the gallery or the system share sheet.
/// The image is never uploaded by us: it is rendered locally, written to the
/// app's temp directory and given straight to the app the user picked.
///
/// The caption carries the Ayma smart link (`justabot.info/get`, the free
/// static Firebase-hosted redirect page — see `public/get.html` and
/// `docs/SMART_LINK.md`) so every card that lands in WhatsApp or the system
/// share sheet comes with a one-tap way into the app (open it, else the
/// right app store). Instagram strips shared text, so there the link rides
/// only on whatever the user adds.
class ReportCardShare {
  ReportCardShare({
    MethodChannel? shareChannel,
    GallerySaver? gallery,
    Directory? tempDir,
    Future<void> Function(ShareParams params)? systemShare,
  }) : _channel = shareChannel ?? const MethodChannel('ayma/share'),
       _gallery = gallery ?? const GallerySaver(),
       _tempDir = tempDir ?? Directory.systemTemp,
       _systemShare =
           systemShare ??
           ((p) async {
             await SharePlus.instance.share(p);
           });

  final MethodChannel _channel;
  final GallerySaver _gallery;
  final Directory _tempDir;
  final Future<void> Function(ShareParams params) _systemShare;

  /// The Ayma smart link: a free, static Firebase-hosted page that redirects
  /// a tapper to the app (deep link), else their app store, else a web page.
  static const shareUrl = 'https://justabot.info/get';

  /// The default caption, link included. [captionFor] adds a referral code.
  static const caption = 'Get your report on Ayma 💘 $shareUrl';

  /// The caption with the sharer's [refCode] appended to the link (the static
  /// page forwards it to Google Play as an `ayma_ref` install referrer, the
  /// same key the backend referral page uses). Falls back to the plain link
  /// when there is no code.
  static String captionFor(String? refCode) {
    final code = refCode?.trim() ?? '';
    final link = code.isEmpty ? shareUrl : '$shareUrl?r=${Uri.encodeComponent(code)}';
    return 'Get your report on Ayma 💘 $link';
  }

  static const pixelRatio = 3.0;

  static const _whatsappPackages = ['com.whatsapp', 'com.whatsapp.w4b'];
  static const _instagramPackages = ['com.instagram.android'];

  /// Longest side, in pixels, a card photo is decoded at: the largest
  /// polaroid is 188x222 logical px, 564x666 px in the 3x export.
  static const photoDecodeSize = 800;

  /// Fully decodes [provider] (downscaled to [photoDecodeSize]) and returns
  /// the image, or null when it fails or takes longer than [timeout] (the
  /// card then leaves that photo out rather than drawing an empty frame).
  static Future<ui.Image?> decode(
    ImageProvider provider, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final done = Completer<ui.Image?>();
    final stream = ResizeImage(
      provider,
      width: photoDecodeSize,
      height: photoDecodeSize,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void finish(ui.Image? image) {
      if (done.isCompleted) {
        image?.dispose();
        return;
      }
      done.complete(image);
      scheduleMicrotask(() => stream.removeListener(listener));
    }

    listener = ImageStreamListener(
      (info, _) => finish(info.image.clone()),
      onError: (_, __) => finish(null),
    );
    stream.addListener(listener);
    return done.future.timeout(
      timeout,
      onTimeout: () {
        finish(null);
        return null;
      },
    );
  }

  /// Renders [card] (a fixed [logicalSize] widget whose photos are
  /// [DecodedImage]s, so they paint on the first frame) offscreen into PNG bytes at [pixelRatio], so
  /// 360x640 becomes 1080x1920. [view] is any attached FlutterView (only used
  /// to satisfy the render tree; nothing is drawn on screen).
  static Future<Uint8List> renderPng(
    Widget card, {
    required ui.FlutterView view,
    required Size logicalSize,
    double ratio = pixelRatio,
  }) async {
    final boundary = RenderRepaintBoundary();
    final renderView = RenderView(
      view: view,
      child: boundary,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(logicalSize),
        physicalConstraints: BoxConstraints.tight(logicalSize * ratio),
        devicePixelRatio: ratio,
      ),
    );
    final pipeline = PipelineOwner()..rootNode = renderView;
    renderView.prepareInitialFrame();
    final focus = FocusManager();
    final buildOwner = BuildOwner(focusManager: focus);
    final tree = MediaQuery(
      data: MediaQueryData(size: logicalSize, devicePixelRatio: ratio),
      child: Directionality(textDirection: TextDirection.ltr, child: card),
    );
    final root = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: tree,
    ).attachToRenderTree(buildOwner);

    void frame() {
      buildOwner.buildScope(root);
      buildOwner.finalizeTree();
      pipeline.flushLayout();
      pipeline.flushCompositingBits();
      pipeline.flushPaint();
    }

    try {
      frame();
      // Wait for the card's fonts (already loaded when the card was shown on
      // screen; a font that can't load in time falls back), then lay out and
      // paint again so text is drawn in its final face.
      try {
        await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Offline, slow or blocked: the fallback face is used instead.
      }
      await Future<void>.delayed(Duration.zero);
      frame();
      final image = await boundary.toImage(pixelRatio: ratio);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PNG encoding failed');
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      // Unmount the offscreen tree so its image listeners and fonts are
      // released.
      RenderObjectToWidgetAdapter<RenderBox>(container: boundary)
          .attachToRenderTree(buildOwner, root);
      buildOwner.buildScope(root);
      buildOwner.finalizeTree();
      focus.dispose();
      pipeline.rootNode = null;
      renderView.dispose();
      pipeline.dispose();
    }
  }

  Future<File> _write(Uint8List png) => File(
    '${_tempDir.path}/ayma_report_card_${DateTime.now().millisecondsSinceEpoch}.png',
  ).writeAsBytes(png, flush: true);

  /// Sends [png] to [target]. Returns a short confirmation to show the user,
  /// or null when the app the user picked takes over. Throws on failure
  /// (a declined gallery permission is a [PlatformException] `PERMISSION`).
  /// [origin] anchors the share popover on iPad.
  Future<String?> share(
    CardShareTarget target,
    Uint8List png, {
    Rect? origin,
    String? caption,
  }) async {
    final text = caption ?? ReportCardShare.caption;
    if (target == CardShareTarget.save) {
      final where = await _gallery.save(
        png,
        'ayma_report_card_${DateTime.now().millisecondsSinceEpoch}.png',
        'image/png',
      );
      return 'Saved to $where';
    }
    final file = await _write(png);
    // WhatsApp and Instagram are targeted directly on Android (a plain
    // image send to that app; Instagram then offers Stories). iOS has no
    // reliable way to hand an image to one app without its SDK, so the
    // system share sheet is used, where both apps appear.
    final packages = switch (target) {
      CardShareTarget.whatsapp => _whatsappPackages,
      CardShareTarget.instagram => _instagramPackages,
      _ => const <String>[],
    };
    if (packages.isNotEmpty &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      final sent = await _channel.invokeMethod<bool>('sendToApp', {
        'path': file.path,
        'packages': packages,
        // Instagram strips EXTRA_TEXT from an image share; only WhatsApp keeps
        // the caption (and its link), so only send it there.
        'text': target == CardShareTarget.whatsapp ? text : '',
      });
      if (sent == true) return null;
    }
    await _systemShare(
      ShareParams(
        text: text,
        files: [XFile(file.path, mimeType: 'image/png')],
        sharePositionOrigin: origin,
      ),
    );
    return null;
  }
}

/// An already-decoded image as an [ImageProvider]: resolves synchronously,
/// so the offscreen export never captures a photo that is still loading.
/// The owner disposes [image] when it is done with it.
class DecodedImage extends ImageProvider<DecodedImage> {
  const DecodedImage(this.image);

  final ui.Image image;

  @override
  Future<DecodedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    DecodedImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image.clone())),
  );
}
