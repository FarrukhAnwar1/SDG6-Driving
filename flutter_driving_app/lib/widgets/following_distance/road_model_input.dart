// Converts upright camera pixels into the pretrained models' normalized inputs.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

enum RoadPixelFormat { yuv420, bgra8888 }

class RoadImagePlane {
  const RoadImagePlane(this.bytes, this.rowStride, this.pixelStride);
  final Uint8List bytes;
  final int rowStride;
  final int pixelStride;
}

class RoadCameraFrame {
  const RoadCameraFrame({
    required this.width,
    required this.height,
    required this.format,
    required this.planes,
    required this.clockwiseRotation,
    required this.timestamp,
  });
  final int width;
  final int height;
  final RoadPixelFormat format;
  final List<RoadImagePlane> planes;
  final int clockwiseRotation;
  // Camera-plugin delivery time, captured before preprocessing or inference.
  final DateTime timestamp;
}

class ModelLetterbox {
  ModelLetterbox(int sourceWidth, int sourceHeight, this.width, this.height)
    : scale = math.min(width / sourceWidth, height / sourceHeight) {
    imageWidth = (sourceWidth * scale).round();
    imageHeight = (sourceHeight * scale).round();
    left = (width - imageWidth) ~/ 2;
    top = (height - imageHeight) ~/ 2;
  }
  final int width, height;
  final double scale;
  late final int imageWidth, imageHeight, left, top;

  Rect toCamera(Rect pixels) => Rect.fromLTRB(
    (pixels.left - left) / imageWidth,
    (pixels.top - top) / imageHeight,
    (pixels.right - left) / imageWidth,
    (pixels.bottom - top) / imageHeight,
  );

  Offset toModel(Offset normalized) => Offset(
    left + normalized.dx * imageWidth,
    top + normalized.dy * imageHeight,
  );
}

class PreparedRoadFrame {
  const PreparedRoadFrame({
    required this.timestamp,
    required this.detector,
    required this.depth,
    required this.detectorLayout,
    required this.depthLayout,
  });
  final DateTime timestamp;
  final Float32List detector, depth;
  final ModelLetterbox detectorLayout, depthLayout;
}

const detectorSide = 640;
// 208,544 pixels, inside UniDepthV2's documented 200k..600k training range.
const depthHeight = 532;
const depthWidth = 392;
const _mean = [0.485, 0.456, 0.406];
const _std = [0.229, 0.224, 0.225];

// Run in a worker isolate. Respect row/pixel strides: Android chroma planes
// are often interleaved, and iOS BGRA rows can include trailing padding.
PreparedRoadFrame prepareRoadFrame(RoadCameraFrame frame) {
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      ![0, 90, 180, 270].contains(frame.clockwiseRotation)) {
    throw const FormatException('Invalid camera dimensions or rotation');
  }
  final swapped = frame.clockwiseRotation % 180 != 0;
  final width = swapped ? frame.height : frame.width;
  final height = swapped ? frame.width : frame.height;
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final (sx, sy) = switch (frame.clockwiseRotation) {
        90 => (y, frame.height - 1 - x),
        180 => (frame.width - 1 - x, frame.height - 1 - y),
        270 => (frame.width - 1 - y, x),
        _ => (x, y),
      };
      final target = (y * width + x) * 3;
      if (frame.format == RoadPixelFormat.bgra8888) {
        final plane = frame.planes.single;
        final source = sy * plane.rowStride + sx * plane.pixelStride;
        rgb[target] = plane.bytes[source + 2];
        rgb[target + 1] = plane.bytes[source + 1];
        rgb[target + 2] = plane.bytes[source];
      } else {
        if (frame.planes.length != 3) {
          throw const FormatException('Expected three YUV planes');
        }
        int read(int p, int px, int py) {
          final plane = frame.planes[p];
          return plane.bytes[py * plane.rowStride + px * plane.pixelStride];
        }

        final luma = (read(0, sx, sy) - 16) * 1.164383;
        final u = read(1, sx ~/ 2, sy ~/ 2) - 128;
        final v = read(2, sx ~/ 2, sy ~/ 2) - 128;
        rgb[target] = (luma + 1.596027 * v).round().clamp(0, 255);
        rgb[target + 1] = (luma - 0.391762 * u - 0.812968 * v).round().clamp(
          0,
          255,
        );
        rgb[target + 2] = (luma + 2.017232 * u).round().clamp(0, 255);
      }
    }
  }
  final detectorLayout = ModelLetterbox(
    width,
    height,
    detectorSide,
    detectorSide,
  );
  final depthLayout = ModelLetterbox(width, height, depthWidth, depthHeight);
  return PreparedRoadFrame(
    timestamp: frame.timestamp,
    detector: _resize(
      rgb,
      width,
      height,
      detectorLayout,
      detectorPadding: true,
    ),
    depth: _resize(rgb, width, height, depthLayout, detectorPadding: false),
    detectorLayout: detectorLayout,
    depthLayout: depthLayout,
  );
}

Float32List _resize(
  Uint8List rgb,
  int width,
  int height,
  ModelLetterbox layout, {
  required bool detectorPadding,
}) {
  final area = layout.width * layout.height;
  final output = Float32List(3 * area);
  if (detectorPadding) {
    for (var c = 0; c < 3; c++) {
      output.fillRange(
        c * area,
        (c + 1) * area,
        (114 / 255 - _mean[c]) / _std[c],
      );
    }
  }
  for (var y = 0; y < layout.imageHeight; y++) {
    final sourceY = ((y + 0.5) * height / layout.imageHeight - 0.5).clamp(
      0.0,
      height - 1.0,
    );
    final y0 = sourceY.floor(), y1 = math.min(y0 + 1, height - 1);
    final fy = sourceY - y0;
    for (var x = 0; x < layout.imageWidth; x++) {
      final sourceX = ((x + 0.5) * width / layout.imageWidth - 0.5).clamp(
        0.0,
        width - 1.0,
      );
      final x0 = sourceX.floor(), x1 = math.min(x0 + 1, width - 1);
      final fx = sourceX - x0;
      final target = (y + layout.top) * layout.width + x + layout.left;
      for (var c = 0; c < 3; c++) {
        final a =
            rgb[(y0 * width + x0) * 3 + c] * (1 - fx) +
            rgb[(y0 * width + x1) * 3 + c] * fx;
        final b =
            rgb[(y1 * width + x0) * 3 + c] * (1 - fx) +
            rgb[(y1 * width + x1) * 3 + c] * fx;
        output[c * area + target] =
            ((a * (1 - fy) + b * fy) / 255 - _mean[c]) / _std[c];
      }
    }
  }
  return output;
}
