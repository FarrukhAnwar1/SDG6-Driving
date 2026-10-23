// Reads rear-camera geometry and adjusts it for upright analysis frames.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

// Focal length and image-plane dimensions use the same units (millimeters on
// Android, pixels on iOS). These describe the detector's camera, not its preview.
class RoadCameraGeometry {
  const RoadCameraGeometry({
    required this.focalLength,
    required this.imagePlaneWidth,
    required this.imagePlaneHeight,
  });

  static const channel = MethodChannel('driver_grading/road_camera_geometry');

  final double focalLength;
  final double imagePlaneWidth;
  final double imagePlaneHeight;

  static Future<RoadCameraGeometry?> read() async {
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('getGeometry')
          .timeout(const Duration(seconds: 2));
      if (data == null ||
          data['focalLength'] is! num ||
          data['imagePlaneWidth'] is! num ||
          data['imagePlaneHeight'] is! num) {
        return null;
      }
      final geometry = RoadCameraGeometry(
        focalLength: (data['focalLength'] as num).toDouble(),
        imagePlaneWidth: (data['imagePlaneWidth'] as num).toDouble(),
        imagePlaneHeight: (data['imagePlaneHeight'] as num).toDouble(),
      );
      return geometry.isValid ? geometry : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  bool get isValid =>
      focalLength.isFinite &&
      focalLength > 0 &&
      imagePlaneWidth.isFinite &&
      imagePlaneWidth > 0 &&
      imagePlaneHeight.isFinite &&
      imagePlaneHeight > 0;

  // The sensor's short side becomes the horizontal axis in portrait. Account
  // for any aspect-ratio crop before normalizing focal length to frame width.
  // Using a landscape FOV unchanged in portrait systematically shortens range.
  double? normalizedFocalLengthFor(Size frame) {
    if (!isValid ||
        !frame.width.isFinite ||
        !frame.height.isFinite ||
        frame.width <= 0 ||
        frame.height <= 0) {
      return null;
    }
    final rotated =
        (frame.width < frame.height) != (imagePlaneWidth < imagePlaneHeight);
    final width = rotated ? imagePlaneHeight : imagePlaneWidth;
    final height = rotated ? imagePlaneWidth : imagePlaneHeight;
    final visibleWidth = math.min(width, height * frame.aspectRatio);
    return focalLength / visibleWidth;
  }
}
