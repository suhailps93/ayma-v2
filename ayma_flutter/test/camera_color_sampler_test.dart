import 'dart:typed_data';

import 'package:ayma_flutter/services/camera_color_sampler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampler = CameraColorSampler();

  group('CameraColorSampler - Hex formatting', () {
    test('formats colors as uppercase #RRGGBB', () {
      expect(CameraColorSampler.toHex(const Color(0xFFDA4B65)), '#DA4B65');
      expect(CameraColorSampler.toHex(const Color(0xFF000000)), '#000000');
      expect(CameraColorSampler.toHex(const Color(0xFFFFFFFF)), '#FFFFFF');
      expect(CameraColorSampler.toHex(const Color(0xFF2E9E5B)), '#2E9E5B');
    });
  });

  group('CameraColorSampler - BGRA8888 sampling', () {
    test('samples solid BGRA pixels correctly', () {
      // 10x10 frame, pure green: B=0, G=255, R=0, A=255
      const width = 10;
      const height = 10;
      final bytes = Uint8List(width * height * 4);
      for (int i = 0; i < bytes.length; i += 4) {
        bytes[i] = 0; // B
        bytes[i + 1] = 255; // G
        bytes[i + 2] = 0; // R
        bytes[i + 3] = 255; // A
      }

      final frame = CameraFrameData(
        width: width,
        height: height,
        format: CameraFrameFormat.bgra8888,
        planes: [
          CameraPlaneData(bytes: bytes, bytesPerRow: width * 4, bytesPerPixel: 4),
        ],
      );

      final sampled = sampler.sampleCenterColor(frame);
      expect(sampled, isNotNull);
      expect(sampled!.r, closeTo(0, 0.05));
      expect(sampled.g, closeTo(1, 0.05));
      expect(sampled.b, closeTo(0, 0.05));
      expect(CameraColorSampler.toHex(sampled), '#00FF00');
    });

    test('averages patch around center pixel for stability', () {
      // 5x5 frame, center 3x3 is white, outer border is black
      const width = 5;
      const height = 5;
      final bytes = Uint8List(width * height * 4);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final idx = (y * width + x) * 4;
          final isCenterPatch = (x >= 1 && x <= 3) && (y >= 1 && y <= 3);
          final val = isCenterPatch ? 255 : 0;
          bytes[idx] = val; // B
          bytes[idx + 1] = val; // G
          bytes[idx + 2] = val; // R
          bytes[idx + 3] = 255; // A
        }
      }

      final frame = CameraFrameData(
        width: width,
        height: height,
        format: CameraFrameFormat.bgra8888,
        planes: [
          CameraPlaneData(bytes: bytes, bytesPerRow: width * 4, bytesPerPixel: 4),
        ],
      );

      // Sampling radius 1 around center (2,2) includes only the 3x3 white patch
      final sampled = sampler.sampleCenterColor(frame, patchRadius: 1);
      expect(sampled, isNotNull);
      expect(CameraColorSampler.toHex(sampled!), '#FFFFFF');

      // Sampling radius 2 includes the 16 border pixels (black) + 9 center pixels (white)
      // avg = (9 * 255) / 25 = 91.8 -> 92
      final sampledWide = sampler.sampleCenterColor(frame, patchRadius: 2);
      expect(sampledWide, isNotNull);
      final int argb = sampledWide!.toARGB32();
      final int r = (argb >> 16) & 0xFF;
      expect(r, closeTo(92, 1));
    });
  });

  group('CameraColorSampler - RGBA8888 sampling', () {
    test('samples RGBA pixel buffer', () {
      const width = 4;
      const height = 4;
      final bytes = Uint8List(width * height * 4);
      for (int i = 0; i < bytes.length; i += 4) {
        bytes[i] = 218; // R
        bytes[i + 1] = 75; // G
        bytes[i + 2] = 101; // B
        bytes[i + 3] = 255; // A
      }

      final frame = CameraFrameData(
        width: width,
        height: height,
        format: CameraFrameFormat.rgba8888,
        planes: [
          CameraPlaneData(bytes: bytes, bytesPerRow: width * 4, bytesPerPixel: 4),
        ],
      );

      final sampled = sampler.sampleCenterColor(frame);
      expect(sampled, isNotNull);
      expect(CameraColorSampler.toHex(sampled!), '#DA4B65');
    });
  });

  group('CameraColorSampler - YUV420 sampling', () {
    test('samples neutral grey in YUV420', () {
      const width = 8;
      const height = 8;
      final yBytes = Uint8List(width * height)..fillRange(0, width * height, 128);
      final uBytes = Uint8List((width ~/ 2) * (height ~/ 2))..fillRange(0, (width ~/ 2) * (height ~/ 2), 128);
      final vBytes = Uint8List((width ~/ 2) * (height ~/ 2))..fillRange(0, (width ~/ 2) * (height ~/ 2), 128);

      final frame = CameraFrameData(
        width: width,
        height: height,
        format: CameraFrameFormat.yuv420,
        planes: [
          CameraPlaneData(bytes: yBytes, bytesPerRow: width, bytesPerPixel: 1),
          CameraPlaneData(bytes: uBytes, bytesPerRow: width ~/ 2, bytesPerPixel: 1),
          CameraPlaneData(bytes: vBytes, bytesPerRow: width ~/ 2, bytesPerPixel: 1),
        ],
      );

      final sampled = sampler.sampleCenterColor(frame);
      expect(sampled, isNotNull);
      final int argb = sampled!.toARGB32();
      final int r = (argb >> 16) & 0xFF;
      final int g = (argb >> 8) & 0xFF;
      final int b = argb & 0xFF;
      expect(r, closeTo(128, 2));
      expect(g, closeTo(128, 2));
      expect(b, closeTo(128, 2));
    });
  });

  group('CameraColorSampler - Error and edge case handling', () {
    test('returns null on zero dimensions or empty planes', () {
      expect(sampler.sampleCenterColor(const CameraFrameData(
        width: 0,
        height: 10,
        format: CameraFrameFormat.bgra8888,
        planes: [],
      )), isNull);

      expect(sampler.sampleCenterColor(const CameraFrameData(
        width: 10,
        height: 0,
        format: CameraFrameFormat.bgra8888,
        planes: [],
      )), isNull);
    });

    test('handles 1x1 image without crashing', () {
      final bytes = Uint8List.fromList([0, 0, 255, 255]); // Red in BGRA
      final frame = CameraFrameData(
        width: 1,
        height: 1,
        format: CameraFrameFormat.bgra8888,
        planes: [
          CameraPlaneData(bytes: bytes, bytesPerRow: 4, bytesPerPixel: 4),
        ],
      );

      final sampled = sampler.sampleCenterColor(frame, patchRadius: 2);
      expect(sampled, isNotNull);
      expect(CameraColorSampler.toHex(sampled!), '#FF0000');
    });
  });
}
