// Verifies camera channel order, image strides, rotation and model normalization.

import 'dart:typed_data';

import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 10, 23);

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
