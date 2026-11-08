// Verifies camera channel order, image strides, rotation and model normalization.

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 10, 23);

  test('depth crop maps full-camera boxes into its actual field of view', () {
    final crop = ModelLetterbox.crop(1000, 500, 400, 500);
    expect(crop.sourceRegion, const Rect.fromLTRB(0.3, 0, 0.7, 1));
    expect(crop.toModel(const Offset(0.3, 0)), const Offset(0, 0));
    expect(crop.toModel(const Offset(0.5, 0.5)).dx, closeTo(200, 1e-9));
    expect(crop.toModel(const Offset(0.7, 1)).dx, closeTo(400, 1e-9));
    final restored = crop.toCamera(const Rect.fromLTRB(0, 0, 400, 500));
    expect(restored.left, closeTo(0.3, 1e-9));
    expect(restored.right, closeTo(0.7, 1e-9));
    expect(crop.toModel(const Offset(0.1, 0.5)).dx, isNegative);
  });

  test(
    'wide depth input contains central scene pixels rather than padding',
    () {
      const width = 100, height = 50;
      final pixels = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final offset = (y * width + x) * 4;
          final inside = x >= 31 && x < 68;
          pixels[offset + 1] = inside ? 255 : 0;
          pixels[offset + 2] = inside ? 0 : 255;
          pixels[offset + 3] = 255;
        }
      }
      final frame = RoadCameraFrame(
        width: width,
        height: height,
        format: RoadPixelFormat.bgra8888,
        planes: [RoadImagePlane(pixels, width * 4, 4)],
        clockwiseRotation: 0,
        timestamp: timestamp,
      );
      final prepared = prepareRoadFrame(frame);
      final legacy = prepareRoadFrame(frame, cropDepth: false);
      expect(legacy.depthLayout.sourceRegion, const Rect.fromLTWH(0, 0, 1, 1));
      expect(legacy.depth[50 * depthWidth + depthWidth ~/ 2], 0);
      expect(prepared.detector, orderedEquals(legacy.detector));
      expect(
        prepared.detectorLayout.sourceRegion,
        const Rect.fromLTWH(0, 0, 1, 1),
      );
      expect(prepared.depthLayout.sourceRegion.left, closeTo(0.31, 1e-9));
      expect(prepared.depthLayout.sourceRegion.right, closeTo(0.68, 1e-9));
      final area = depthWidth * depthHeight;
      for (final row in [50, depthHeight ~/ 2, depthHeight - 50]) {
        final index = row * depthWidth + depthWidth ~/ 2;
        expect(prepared.depth[index], closeTo(-0.485 / 0.229, 1e-6));
        expect(
          prepared.depth[area + index],
          closeTo((1 - 0.456) / 0.224, 1e-6),
        );
      }
      // The detector still sees the red area outside the depth crop.
      expect(
        prepared.detector[320 * 640 + 32],
        closeTo((1 - 0.485) / 0.229, 1e-6),
      );
    },
  );

  test('normal portrait camera crop preserves almost the entire image', () {
    final crop = ModelLetterbox.crop(480, 640, depthWidth, depthHeight);
    expect(crop.sourceRegion.height, 1);
    expect(crop.sourceRegion.width, closeTo(472 / 480, 1e-9));
    expect(crop.sourceRegion.left, closeTo(4 / 480, 1e-9));
  });

  test('BGRA row padding and ImageNet channels are respected', () {
    final bytes = Uint8List.fromList([
      30,
      20,
      10,
      255,
      30,
      20,
      10,
      255,
      99,
      99,
      99,
      99,
      30,
      20,
      10,
      255,
      30,
      20,
      10,
      255,
    ]);
    final prepared = prepareRoadFrame(
      RoadCameraFrame(
        width: 2,
        height: 2,
        format: RoadPixelFormat.bgra8888,
        planes: [RoadImagePlane(bytes, 12, 4)],
        clockwiseRotation: 0,
        timestamp: timestamp,
      ),
    );
    final center = 320 * 640 + 320, area = 640 * 640;
    expect(
      prepared.detector[center],
      closeTo((10 / 255 - 0.485) / 0.229, 1e-6),
    );
    expect(
      prepared.detector[area + center],
      closeTo((20 / 255 - 0.456) / 0.224, 1e-6),
    );
    expect(
      prepared.detector[2 * area + center],
      closeTo((30 / 255 - 0.406) / 0.225, 1e-6),
    );
    expect(prepared.timestamp, timestamp);
  });

  test('sensor landscape rotates clockwise into upright portrait', () {
    final bytes = Uint8List.fromList([0, 0, 255, 255, 0, 0, 0, 255]);
    final prepared = prepareRoadFrame(
      RoadCameraFrame(
        width: 2,
        height: 1,
        format: RoadPixelFormat.bgra8888,
        planes: [RoadImagePlane(bytes, 8, 4)],
        clockwiseRotation: 90,
        timestamp: timestamp,
      ),
    );
    expect(prepared.detectorLayout.imageWidth, 320);
    expect(prepared.detectorLayout.imageHeight, 640);
    final topRed = prepared.detector[100 * 640 + 320];
    final bottomRed = prepared.detector[540 * 640 + 320];
    expect(topRed, closeTo((1 - 0.485) / 0.229, 1e-6));
    expect(bottomRed, closeTo(-0.485 / 0.229, 1e-6));
  });

  test('YUV420 interleaved chroma planes produce neutral white', () {
    final prepared = prepareRoadFrame(
      RoadCameraFrame(
        width: 2,
        height: 2,
        format: RoadPixelFormat.yuv420,
        planes: [
          RoadImagePlane(Uint8List.fromList([235, 235, 99, 235, 235]), 3, 1),
          RoadImagePlane(Uint8List.fromList([128, 99]), 2, 2),
          RoadImagePlane(Uint8List.fromList([128, 99]), 2, 2),
        ],
        clockwiseRotation: 0,
        timestamp: timestamp,
      ),
    );
    expect(
      prepared.detector[320 * 640 + 320],
      closeTo((1 - 0.485) / 0.229, 1e-6),
    );
  });
}
