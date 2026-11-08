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
  ModelLetterbox(int sourceWidth, int sourceHeight, int width, int height)
    : this._(
        sourceWidth,
        sourceHeight,
        width,
        height,
        const Rect.fromLTWH(0, 0, 1, 1),
      );

  // Fill the fixed depth-network input with a centered, aspect-preserving crop.
  // The detector still sees the full camera image. Keep this region in camera
  // coordinates so depth lookups cannot mistake cropped pixels for full-frame
  // pixels or sample a vehicle outside the depth network's field of view.
  factory ModelLetterbox.crop(
    int sourceWidth,
    int sourceHeight,
    int width,
    int height,
  ) {
    var cropWidth = sourceWidth, cropHeight = sourceHeight;
    if (sourceWidth * height > sourceHeight * width) {
      cropWidth = (sourceHeight * width / height).round().clamp(1, sourceWidth);
    } else {
      cropHeight = (sourceWidth * height / width).round().clamp(
        1,
        sourceHeight,
      );
    }
    final cropLeft = (sourceWidth - cropWidth) ~/ 2;
    final cropTop = (sourceHeight - cropHeight) ~/ 2;
    return ModelLetterbox._(
      sourceWidth,
      sourceHeight,
      width,
      height,
      Rect.fromLTWH(
        cropLeft / sourceWidth,
        cropTop / sourceHeight,
        cropWidth / sourceWidth,
        cropHeight / sourceHeight,
      ),
    );
  }

  ModelLetterbox._(
    int sourceWidth,
    int sourceHeight,
    this.width,
    this.height,
    this.sourceRegion,
  ) : scale = math.min(
        width / (sourceWidth * sourceRegion.width),
        height / (sourceHeight * sourceRegion.height),
      ) {
    imageWidth = (sourceWidth * sourceRegion.width * scale).round();
    imageHeight = (sourceHeight * sourceRegion.height * scale).round();
    left = (width - imageWidth) ~/ 2;
    top = (height - imageHeight) ~/ 2;
  }
  final int width, height;
  final double scale;
  final Rect sourceRegion;
  late final int imageWidth, imageHeight, left, top;

  Rect toCamera(Rect pixels) => Rect.fromLTRB(
    sourceRegion.left + (pixels.left - left) / imageWidth * sourceRegion.width,
    sourceRegion.top + (pixels.top - top) / imageHeight * sourceRegion.height,
    sourceRegion.left + (pixels.right - left) / imageWidth * sourceRegion.width,
    sourceRegion.top +
        (pixels.bottom - top) / imageHeight * sourceRegion.height,
  );

  Offset toModel(Offset normalized) => Offset(
    left +
        (normalized.dx - sourceRegion.left) / sourceRegion.width * imageWidth,
    top +
        (normalized.dy - sourceRegion.top) / sourceRegion.height * imageHeight,
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
PreparedRoadFrame prepareRoadFrame(
  RoadCameraFrame frame, {
  bool cropDepth = true,
}) {
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
  final depthLayout = cropDepth
      ? ModelLetterbox.crop(width, height, depthWidth, depthHeight)
      : ModelLetterbox(width, height, depthWidth, depthHeight);
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
  final sourceLeft = (layout.sourceRegion.left * width).round();
  final sourceTop = (layout.sourceRegion.top * height).round();
  final sourceWidth = (layout.sourceRegion.width * width).round();
  final sourceHeight = (layout.sourceRegion.height * height).round();
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
    final sourceY =
        ((y + 0.5) * sourceHeight / layout.imageHeight - 0.5).clamp(
          0.0,
          sourceHeight - 1.0,
        ) +
        sourceTop;
    final y0 = sourceY.floor(),
        y1 = math.min(y0 + 1, sourceTop + sourceHeight - 1);
    final fy = sourceY - y0;
    for (var x = 0; x < layout.imageWidth; x++) {
      final sourceX =
          ((x + 0.5) * sourceWidth / layout.imageWidth - 0.5).clamp(
            0.0,
            sourceWidth - 1.0,
          ) +
          sourceLeft;
      final x0 = sourceX.floor(),
          x1 = math.min(x0 + 1, sourceLeft + sourceWidth - 1);
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
