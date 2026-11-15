import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Supported image formats for frame color sampling.
enum CameraFrameFormat {
  yuv420,
  bgra8888,
  rgba8888,
  unknown,
}

/// A single image plane's buffer and stride geometry.
class CameraPlaneData {
  const CameraPlaneData({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}

/// Abstracted frame data allowing camera frames to be tested without hardware.
class CameraFrameData {
  const CameraFrameData({
    required this.width,
    required this.height,
    required this.format,
    required this.planes,
  });

  final int width;
  final int height;
  final CameraFrameFormat format;
  final List<CameraPlaneData> planes;

  /// Adapts a live [CameraImage] from `camera` into [CameraFrameData].
  factory CameraFrameData.fromCameraImage(CameraImage image) {
    CameraFrameFormat format;
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        format = CameraFrameFormat.yuv420;
        break;
      case ImageFormatGroup.bgra8888:
        format = CameraFrameFormat.bgra8888;
        break;
      default:
        format = CameraFrameFormat.unknown;
    }

    return CameraFrameData(
      width: image.width,
      height: image.height,
      format: format,
      planes: image.planes
          .map((p) => CameraPlaneData(
                bytes: p.bytes,
                bytesPerRow: p.bytesPerRow,
                bytesPerPixel: p.bytesPerPixel,
              ))
          .toList(growable: false),
    );
  }
}

/// Samples live colors under the center of a camera preview frame.
///
/// Averages a small square patch around the frame's center pixel for stability,
/// and returns the resulting [Color]. Frames are processed purely in-memory and
/// never saved.
class CameraColorSampler {
  const CameraColorSampler();

  /// Reads the color under the center of [frame], averaging a square patch of
  /// radius [patchRadius] (e.g. radius 2 = 5x5 patch) for stability.
  Color? sampleCenterColor(CameraFrameData frame, {int patchRadius = 2}) {
    if (frame.width <= 0 || frame.height <= 0 || frame.planes.isEmpty) {
      return null;
    }

    final int cx = frame.width ~/ 2;
    final int cy = frame.height ~/ 2;

    int rSum = 0;
    int gSum = 0;
    int bSum = 0;
    int count = 0;

    for (int dy = -patchRadius; dy <= patchRadius; dy++) {
      final int y = cy + dy;
      if (y < 0 || y >= frame.height) continue;

      for (int dx = -patchRadius; dx <= patchRadius; dx++) {
        final int x = cx + dx;
        if (x < 0 || x >= frame.width) continue;

        final Color? pixel = _readPixel(frame, x, y);
        if (pixel != null) {
          final int argb = pixel.toARGB32();
          rSum += (argb >> 16) & 0xFF;
          gSum += (argb >> 8) & 0xFF;
          bSum += argb & 0xFF;
          count++;
        }
      }
    }

    if (count == 0) return null;

    final int avgR = (rSum / count).round().clamp(0, 255);
    final int avgG = (gSum / count).round().clamp(0, 255);
    final int avgB = (bSum / count).round().clamp(0, 255);

    return AymaColors.fromARGB(255, avgR, avgG, avgB);
  }

  /// Convenience method directly from a live [CameraImage].
  Color? sampleFromCameraImage(CameraImage image, {int patchRadius = 2}) {
    final frame = CameraFrameData.fromCameraImage(image);
    return sampleCenterColor(frame, patchRadius: patchRadius);
  }

  /// Formats [color] as `#RRGGBB`.
  static String toHex(Color color) {
    final int argb = color.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Color? _readPixel(CameraFrameData frame, int x, int y) {
    switch (frame.format) {
      case CameraFrameFormat.yuv420:
        return _readYuv420Pixel(frame, x, y);
      case CameraFrameFormat.bgra8888:
        return _readBgraPixel(frame, x, y);
      case CameraFrameFormat.rgba8888:
        return _readRgbaPixel(frame, x, y);
      case CameraFrameFormat.unknown:
        if (frame.planes.length >= 3) {
          return _readYuv420Pixel(frame, x, y);
        } else if (frame.planes.length == 1 &&
            frame.planes[0].bytes.length >= frame.width * frame.height * 4) {
          return _readBgraPixel(frame, x, y);
        }
        return null;
    }
  }

  Color? _readYuv420Pixel(CameraFrameData frame, int x, int y) {
    if (frame.planes.length < 3) return null;
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final int yRowStride = yPlane.bytesPerRow;
    final int yPixelStride = yPlane.bytesPerPixel ?? 1;
    final int yIndex = y * yRowStride + x * yPixelStride;
    if (yIndex < 0 || yIndex >= yPlane.bytes.length) return null;
    final int yValue = yPlane.bytes[yIndex];

    final int uvRow = y >> 1;
    final int uvCol = x >> 1;

    final int uRowStride = uPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uIndex = uvRow * uRowStride + uvCol * uPixelStride;
    if (uIndex < 0 || uIndex >= uPlane.bytes.length) return null;
    final int uValue = uPlane.bytes[uIndex] - 128;

    final int vRowStride = vPlane.bytesPerRow;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;
    final int vIndex = uvRow * vRowStride + uvCol * vPixelStride;
    if (vIndex < 0 || vIndex >= vPlane.bytes.length) return null;
    final int vValue = vPlane.bytes[vIndex] - 128;

    final int r = (yValue + 1.402 * vValue).round().clamp(0, 255);
    final int g =
        (yValue - 0.344136 * uValue - 0.714136 * vValue).round().clamp(0, 255);
    final int b = (yValue + 1.772 * uValue).round().clamp(0, 255);

    return AymaColors.fromARGB(255, r, g, b);
  }

  Color? _readBgraPixel(CameraFrameData frame, int x, int y) {
    final plane = frame.planes[0];
    final int rowStride = plane.bytesPerRow;
    final int pixelStride = plane.bytesPerPixel ?? 4;
    final int index = y * rowStride + x * pixelStride;
    if (index + 3 >= plane.bytes.length) return null;

    final int b = plane.bytes[index];
    final int g = plane.bytes[index + 1];
    final int r = plane.bytes[index + 2];

    return AymaColors.fromARGB(255, r, g, b);
  }

  Color? _readRgbaPixel(CameraFrameData frame, int x, int y) {
    final plane = frame.planes[0];
    final int rowStride = plane.bytesPerRow;
    final int pixelStride = plane.bytesPerPixel ?? 4;
    final int index = y * rowStride + x * pixelStride;
    if (index + 3 >= plane.bytes.length) return null;

    final int r = plane.bytes[index];
    final int g = plane.bytes[index + 1];
    final int b = plane.bytes[index + 2];

    return AymaColors.fromARGB(255, r, g, b);
  }
}
