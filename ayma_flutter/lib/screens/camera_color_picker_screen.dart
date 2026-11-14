import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/accent_color_controller.dart';
import '../services/camera_color_sampler.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/overflow_guards.dart';

/// Live circular camera color picker for sampling accent colors.
///
/// Features:
/// - Circular live preview from the BACK camera only.
/// - Center ring marking the exact live sampling point.
/// - Real-time pixel patch averaging displaying a swatch and hex code next to the circle.
/// - "Use this color" persists the color as user accent and as a Custom swatch.
/// - Requests camera permission on open; shows a plain message and closes on denial.
/// - Never captures or saves photos — frames are only sampled in-memory.
class CameraColorPickerScreen extends StatefulWidget {
  const CameraColorPickerScreen({
    super.key,
    this.controller,
    this.accentController,
    this.requestPermission,
    this.availableCamerasOverride,
    this.initialColor,
    this.bypassCameraInit = false,
  });

  static const path = '/settings/appearance/camera-color-picker';

  final CameraController? controller;
  final AccentColorController? accentController;
  final Future<bool> Function()? requestPermission;
  final Future<List<CameraDescription>> Function()? availableCamerasOverride;
  final Color? initialColor;
  final bool bypassCameraInit;

  @override
  State<CameraColorPickerScreen> createState() =>
      _CameraColorPickerScreenState();
}

class _CameraColorPickerScreenState extends State<CameraColorPickerScreen> {
  CameraController? _controller;
  final CameraColorSampler _sampler = const CameraColorSampler();

  late Color _currentColor =
      widget.initialColor ?? widget.accentController?.color ?? AymaColors.accent;

  bool _isSampling = false;
  bool _closed = false;

  AccentColorController get _accent =>
      widget.accentController ?? accentColorControllerGlobal;

  @override
  void initState() {
    super.initState();
    _initPicker();
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller?.dispose();
    }
    super.dispose();
  }

  Future<void> _initPicker() async {
    final granted = widget.requestPermission != null
        ? await widget.requestPermission!()
        : await _requestCameraPermission();

    if (!granted) {
      _onPermissionDenied();
      return;
    }

    if (widget.controller != null || widget.bypassCameraInit) {
      _controller = widget.controller;
      if (mounted) setState(() {});
      return;
    }

    await _initLiveCamera();
  }

  Future<bool> _requestCameraPermission() async {
    try {
      final status = await Permission.camera.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  void _onPermissionDenied() {
    if (_closed || !mounted) return;
    _closed = true;
    AymaToast.show(context, 'Camera permission is required to sample colours.');
    Navigator.of(context).pop();
  }

  Future<void> _initLiveCamera() async {
    try {
      final cameras = widget.availableCamerasOverride != null
          ? await widget.availableCamerasOverride!()
          : await availableCameras();

      if (cameras.isEmpty) {
        if (!_closed && mounted) {
          _closed = true;
          AymaToast.show(context, 'No camera available.');
          Navigator.of(context).pop();
        }
        return;
      }

      // Back camera only
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      _controller = controller;

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      await controller.startImageStream((CameraImage image) {
        if (_isSampling || !mounted) return;
        _isSampling = true;
        try {
          final sampled = _sampler.sampleFromCameraImage(image);
          if (sampled != null && mounted) {
            setState(() => _currentColor = sampled);
          }
        } catch (_) {
          // Ignore stream decode errors
        } finally {
          _isSampling = false;
        }
      });

      if (mounted) setState(() {});
    } catch (_) {
      if (!_closed && mounted) {
        _closed = true;
        AymaToast.show(context, 'Could not open the camera.');
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _useThisColor() async {
    await _accent.set(_currentColor);
    await _accent.saveCustomColor(_currentColor);
    if (mounted) {
      Navigator.of(context).pop(_currentColor);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Pick from camera'),
      ),
      body: SafeArea(
        child: ChromeColumn(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Point the back camera at any colour to sample it live.',
                  style: AymaType.sans(size: 14, color: ac.fgDim),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // Circular live preview with sampling center ring and swatch next to it
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 20,
                  runSpacing: 16,
                  children: [
                    // Circular camera preview
                    SizedBox(
                      width: 180,
                      height: 180,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          ClipOval(
                            child: SizedBox(
                              width: 180,
                              height: 180,
                              child: _controller != null &&
                                      _controller!.value.isInitialized
                                  ? FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: _controller!
                                                .value.previewSize?.height ??
                                            180,
                                        height: _controller!
                                                .value.previewSize?.width ??
                                            180,
                                        child: CameraPreview(_controller!),
                                      ),
                                    )
                                  : Container(
                                      key: const Key('cameraPreviewFallback'),
                                      color: ac.bgElev,
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.camera_alt_outlined,
                                        size: 40,
                                        color: ac.fgMute,
                                      ),
                                    ),
                            ),
                          ),
                          // Center sampling ring
                          IgnorePointer(
                            child: Container(
                              key: const Key('samplingCenterRing'),
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Swatch and hex value next to the circle
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Picked color',
                          style: AymaType.sans(
                              size: 12, soft: true, color: ac.fgMute),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              key: const Key('pickedColorSwatch'),
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: _currentColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: ac.fg, width: 1.5),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black12,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              CameraColorSampler.toHex(_currentColor),
                              key: const Key('pickedColorHex'),
                              style: AymaType.mono(
                                size: 15,
                                weight: FontWeight.w600,
                                color: ac.fg,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          footer: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('useThisColorButton'),
                  onPressed: _useThisColor,
                  child: const Text('Use this color'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
