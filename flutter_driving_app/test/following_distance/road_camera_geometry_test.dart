// Tests camera metadata, orientation, cropping, and projection scale.

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_geometry.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const geometry = RoadCameraGeometry(
    focalLength: 4,
    imagePlaneWidth: 6,
    imagePlaneHeight: 4.5,
  );

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      null,
    );
  });

  test('portrait focal length uses the short sensor dimension', () {
    expect(
      geometry.normalizedFocalLengthFor(const Size(640, 480)),
      closeTo(4 / 6, 1e-9),
    );
    expect(
      geometry.normalizedFocalLengthFor(const Size(480, 640)),
      closeTo(4 / 4.5, 1e-9),
    );
  });

  test(
    'aspect-ratio crop and resolution are accounted for independently of preview',
    () {
      expect(
        geometry.normalizedFocalLengthFor(const Size(1280, 720)),
        closeTo(4 / 6, 1e-9),
      );
      expect(
        geometry.normalizedFocalLengthFor(const Size(720, 1280)),
        closeTo(4 / (6 * 9 / 16), 1e-9),
      );
      expect(
        geometry.normalizedFocalLengthFor(const Size(960, 1280)),
        geometry.normalizedFocalLengthFor(const Size(480, 640)),
      );
    },
  );

  test('a known 30m car retains its range in both camera orientations', () {
    for (final frame in [const Size(640, 480), const Size(480, 640)]) {
      final focal = geometry.normalizedFocalLengthFor(frame)!;
      final boxWidth = 1.8 * focal / 30;
      final result = VehicleDistanceEstimator(normalizedFocalLength: focal)
          .estimate(
            detections: [
              VehicleDetection(
                label: 'car',
                confidence: 0.9,
                normalizedBox: Rect.fromCenter(
                  center: const Offset(0.5, 0.4),
                  width: boxWidth,
                  height: boxWidth * frame.aspectRatio,
                ),
              ),
            ],
            timestamp: DateTime.utc(2026, 10, 23),
          );
      expect(result.status, FollowingDistanceStatus.tracking);
      expect(result.distanceMeters, closeTo(30, 1e-9));
    }
  });

  test('iOS pixel-space FOV metadata matches Android physical geometry', () {
    final horizontalDegrees = 2 * math.atan(6 / (2 * 4)) * 180 / math.pi;
    final ios = RoadCameraGeometry(
      focalLength: 4032 / (2 * math.tan(horizontalDegrees * math.pi / 360)),
      imagePlaneWidth: 4032,
      imagePlaneHeight: 3024,
    );
    expect(
      ios.normalizedFocalLengthFor(const Size(480, 640)),
      closeTo(geometry.normalizedFocalLengthFor(const Size(480, 640))!, 1e-9),
    );
  });

  test('invalid geometry or frame dimensions cannot produce a distance', () {
    for (final focal in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        RoadCameraGeometry(
          focalLength: focal,
          imagePlaneWidth: 6,
          imagePlaneHeight: 4.5,
        ).normalizedFocalLengthFor(const Size(480, 640)),
        isNull,
      );
    }
    for (final frame in [
      Size.zero,
      const Size(double.nan, 640),
      const Size(480, double.infinity),
    ]) {
      expect(geometry.normalizedFocalLengthFor(frame), isNull);
    }
  });

  test('platform geometry is read without a guessed fallback', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      (call) async {
        expect(call.method, 'getGeometry');
        return {
          'focalLength': 4,
          'imagePlaneWidth': 6.0,
          'imagePlaneHeight': 4.5,
        };
      },
    );
    expect((await RoadCameraGeometry.read())!.focalLength, 4);
    for (final response in [
      null,
      <String, Object>{},
      {'focalLength': 0, 'imagePlaneWidth': 6, 'imagePlaneHeight': 4.5},
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RoadCameraGeometry.channel,
        (_) async => response,
      );
      expect(await RoadCameraGeometry.read(), isNull);
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      (_) async => throw PlatformException(code: 'camera_metadata_unavailable'),
    );
    expect(await RoadCameraGeometry.read(), isNull);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      null,
    );
    expect(await RoadCameraGeometry.read(), isNull);
  });
}
