import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/gallery_saver.dart';
import '../theme.dart';
import 'ayma_toast.dart';

/// Full-screen image viewer shared by the Ayma chat transcript and DM
/// threads: black ground, pinch / double-tap zoom, swipe-down or X to
/// dismiss, plus share (system share sheet) and download (device gallery)
/// actions on the actual image bytes.
///
/// Works for both a network [url] (rendered via the same disk cache
/// `AymaPhoto` fills, so an already-seen photo opens instantly) and a local
/// [file] still mid-upload. When both are present the local file wins — it's
/// the same pixels without a network round trip.
class AymaImageViewer extends StatefulWidget {
  const AymaImageViewer({super.key, this.url, this.file, this.heroTag})
    : assert(url != null || file != null, 'need a url or a file');

  final String? url;
  final File? file;

  /// Test seam: the cache manager backing the network-image path (both the
  /// on-screen [CachedNetworkImage] and the share/download byte fetch).
  /// Production leaves this null and uses the shared [DefaultCacheManager] —
  /// the same disk cache `AymaPhoto` fills. Widget tests inject a fake that
  /// serves a local fixture file, so the real layout/decode pipeline runs
  /// with no platform channels or network.
  @visibleForTesting
  static BaseCacheManager? debugCacheManager;

  static BaseCacheManager get _cache =>
      debugCacheManager ?? DefaultCacheManager();

  /// When non-null, the viewer's image is wrapped in a [Hero] with this tag —
  /// pair it with a Hero around the tapped thumbnail for a flight transition.
  final Object? heroTag;

  /// Pushes the viewer as a fade-in, fully OPAQUE fullscreen dialog on the
  /// root navigator — so it covers everything underneath, whether the chat
  /// lives in the main shell or inside `showAymaChatModal`'s popup sheet
  /// (founder bug, build 2061: the viewer opened as a translucent strip with
  /// the whole chat still visible behind it).
  static Future<void> open(
    BuildContext context, {
    String? url,
    File? file,
    Object? heroTag,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        // Opaque: once the fade completes, nothing below this route paints —
        // the black ground is guaranteed to be the only thing on screen.
        opaque: true,
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) =>
            AymaImageViewer(url: url, file: file, heroTag: heroTag),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<AymaImageViewer> createState() => _AymaImageViewerState();
}

class _AymaImageViewerState extends State<AymaImageViewer> {
  final _transform = TransformationController();
  bool _zoomed = false;
  double _dragY = 0;
  bool _busy = false;
  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _transform.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
    } else {
      final p =
          _doubleTapAt ??
          Offset(
            MediaQuery.of(context).size.width / 2,
            MediaQuery.of(context).size.height / 2,
          );
      const s = 2.5;
      _transform.value = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
  }

  void _endDrag(DragEndDetails d) {
    final fling = d.velocity.pixelsPerSecond.dy.abs() > 700;
    if (_dragY.abs() > 110 || (fling && _dragY.abs() > 24)) {
      Navigator.of(context).pop();
    } else {
      setState(() => _dragY = 0);
    }
  }

  // ---- bytes ---------------------------------------------------------------

  /// The image as a local file: the mid-upload file itself, or the network
  /// image out of (or freshly into) the shared disk cache.
  Future<File> _localFile() async {
    if (widget.file != null) return widget.file!;
    return AymaImageViewer._cache.getSingleFile(widget.url!);
  }

  static String _sniffMime(Uint8List bytes) {
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'image/jpeg';
    }
    if (bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49) {
      return 'image/gif';
    }
    if (bytes.length > 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  static String _extFor(String mime) => switch (mime) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'jpg',
  };

  void _toast(String message, {AymaToastKind kind = AymaToastKind.info}) {
    if (!mounted) return;
    AymaToast.show(context, message, kind: kind);
  }

  // ---- share ---------------------------------------------------------------

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    // iPads require an origin rect for the share popover — resolve it before
    // any await, while the context is synchronously valid.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? (box.localToGlobal(Offset.zero) & box.size)
        : Rect.zero;
    try {
      final f = await _localFile();
      final mime = _sniffMime(await f.readAsBytes());
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(f.path, mimeType: mime)],
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      _toast("Couldn't share that image.", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- download ------------------------------------------------------------

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await (await _localFile()).readAsBytes();
      final mime = _sniffMime(bytes);
      final name =
          'ayma_${DateTime.now().millisecondsSinceEpoch}.${_extFor(mime)}';
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final where = await const GallerySaver().save(bytes, name, mime);
        _toast('Saved to $where', kind: AymaToastKind.success);
      } else {
        // No lightweight gallery hook off Android — the system share sheet's
        // "Save Image" covers it.
        setState(() => _busy = false);
        await _share();
        return;
      }
    } on PlatformException catch (e) {
      _toast(
        e.code == 'PERMISSION'
            ? 'Ayma needs storage access to save photos.'
            : "Couldn't save that image.",
      kind: AymaToastKind.error,
);
    } catch (_) {
      _toast("Couldn't save that image.", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- build ---------------------------------------------------------------

  Widget _image() {
    // `fit: contain` inside a box that always fills the whole viewport (the
    // SizedBox.expand in build): the image paints centered and letterboxed
    // whatever its resolution — a low-res image scales UP to the viewport
    // too, instead of laying out at its intrinsic pixel size.
    Widget image = widget.file != null
        ? Image.file(widget.file!, fit: BoxFit.contain)
        : CachedNetworkImage(
            imageUrl: widget.url!,
            cacheManager: AymaImageViewer.debugCacheManager,
            fit: BoxFit.contain,
            // Static placeholder (like AymaPhoto's): the black ground simply
            // holds until the cached/network image fades in.
            placeholder: (_, __) => const SizedBox.expand(),
            errorWidget: (_, __, ___) => Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: AymaTokens.dark.fgMute,
                size: 40,
              ),
            ),
          );
    if (widget.heroTag != null) {
      // The Hero wraps the contain-fit image and is expanded to the full
      // viewport by build's SizedBox.expand — so the flight from the chat
      // thumbnail lands on a correctly sized, centered, stable box (never on
      // the image's not-yet-decoded intrinsic size).
      image = Hero(tag: widget.heroTag!, child: image);
    }
    return image;
  }

  @override
  Widget build(BuildContext context) {
    // Dark chrome regardless of app theme — a photo viewer is always black.
    final ink = AymaTokens.dark.fg;

    // Layout invariants (founder bug, build 2061 — the viewer rendered as a
    // 60px strip pinned at the top with the chat visible behind it):
    //  * Scaffold lays its body out with LOOSE constraints, and a default
    //    (StackFit.loose) Stack shrink-wraps to its non-positioned children
    //    — which was just the ~60px controls row, collapsing the whole
    //    viewer (black ground and image included, both Positioned.fill) to
    //    a strip at the top. StackFit.expand forces the body fullscreen.
    //  * The Scaffold itself is opaque black: the ground behind the status /
    //    nav bars too, with SafeArea only around the control buttons.
    //  * resizeToAvoidBottomInset: false — a still-open keyboard under the
    //    chat must not shrink the viewer.
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _zoomed
                ? null
                : (d) => setState(() => _dragY += d.delta.dy),
            onVerticalDragEnd: _zoomed ? null : _endDrag,
            onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
            onDoubleTap: _toggleZoom,
            child: Transform.translate(
              offset: Offset(0, _dragY),
              child: InteractiveViewer(
                transformationController: _transform,
                // Single-finger pan only once zoomed in — otherwise the
                // drag belongs to swipe-down-to-dismiss above.
                panEnabled: _zoomed,
                minScale: 1,
                maxScale: 5,
                // Expand to the viewport so pinch/double-tap zoom works from
                // the contain fit and the image is centered by its own
                // alignment — see _image().
                child: SizedBox.expand(child: _image()),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    _ChromeButton(
                      icon: Icons.close,
                      label: 'Close',
                      ink: ink,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    if (_busy)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: ink,
                          ),
                        ),
                      ),
                    _ChromeButton(
                      icon: Icons.share_outlined,
                      label: 'Share',
                      ink: ink,
                      onTap: _share,
                    ),
                    const SizedBox(width: 8),
                    _ChromeButton(
                      icon: Icons.download_outlined,
                      label: 'Save',
                      ink: ink,
                      onTap: _download,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A round scrim-backed icon button — the viewer's minimal chrome.
class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.label,
    required this.ink,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: ink, size: 22),
      tooltip: label,
      style: IconButton.styleFrom(backgroundColor: AymaColors.scrimBusy),
      onPressed: onTap,
    );
  }
}
