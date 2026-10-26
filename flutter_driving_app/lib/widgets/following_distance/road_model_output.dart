// Decodes YOLOP road detections and samples UniDepthV2 metric vehicle depth.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'following_distance_measurement.dart';
import 'road_model_input.dart';

class RoadVehicleObservation {
  const RoadVehicleObservation({
    required this.detection,
    required this.inEgoLane,
    this.distanceMeters,
  });
  final VehicleDetection detection;
  final bool inEgoLane;
  final double? distanceMeters;
}

class RoadObservation {
  const RoadObservation({
    required this.timestamp,
    required this.vehicles,
    required this.roadVisible,
  });
  final DateTime timestamp;
  final List<RoadVehicleObservation> vehicles;
  final bool roadVisible;
}

class RoadModelOutput {
  const RoadModelOutput({
    required this.frame,
    required this.detections,
    required this.drivable,
    required this.lanes,
    required this.depth,
    required this.confidence,
    required this.intrinsics,
  });
  final PreparedRoadFrame frame;
  final Float32List detections, drivable, lanes, depth, confidence, intrinsics;
}

// Worker-isolate postprocessing. Shapes and output names are checked against
// the pinned model contract before any observation can reach the grader.
RoadObservation decodeRoadModels(RoadModelOutput output) {
  final frame = output.frame;
  final area = detectorSide * detectorSide;
  if (output.detections.length != 25200 * 6 ||
      output.drivable.length != area * 2 ||
      output.lanes.length != area * 2 ||
      output.depth.length != depthWidth * depthHeight ||
      output.confidence.length != output.depth.length ||
      output.intrinsics.length != 9 ||
      output.intrinsics.any((value) => !value.isFinite) ||
      output.intrinsics[0] <= 0 ||
      output.intrinsics[4] <= 0) {
    throw const FormatException('Unexpected road model output');
  }
  final candidates = <VehicleDetection>[];
  for (var offset = 0; offset < output.detections.length; offset += 6) {
    final values = output.detections;
    final confidence = values[offset + 4] * values[offset + 5];
    // Keep weak boxes for lead continuity; a new lead needs 0.25 downstream.
    if (!confidence.isFinite || confidence < 0.1 || confidence > 1) {
      continue;
    }
    final cx = values[offset], cy = values[offset + 1];
    final w = values[offset + 2], h = values[offset + 3];
    if (![cx, cy, w, h].every((value) => value.isFinite) || w < 2 || h < 2) {
      continue;
    }
    final box = frame.detectorLayout.toCamera(
      Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
    );
    if (box.center.dx <= 0 ||
        box.center.dx >= 1 ||
        box.center.dy <= 0 ||
        box.center.dy >= 1) {
      continue;
    }
    candidates.add(
      VehicleDetection(
        label: 'vehicle',
        confidence: confidence,
        normalizedBox: box,
      ),
    );
  }
  candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <VehicleDetection>[];
  for (final candidate in candidates.take(300)) {
    if (kept.every(
      (other) =>
          _boxIntersectionOverUnion(
            candidate.normalizedBox,
            other.normalizedBox,
          ) <=
          0.45,
    )) {
      kept.add(candidate);
      if (kept.length == 50) break;
    }
  }
  bool mask(Float32List scores, double x, double y) {
    final point = frame.detectorLayout.toModel(Offset(x, y));
    final ix = point.dx.floor().clamp(0, detectorSide - 1);
    final iy = point.dy.floor().clamp(0, detectorSide - 1);
    final index = iy * detectorSide + ix;
    return scores[index].isFinite &&
        scores[area + index].isFinite &&
        scores[area + index] > scores[index];
  }

  var roadPixels = 0;
  for (var y = 0; y < 10; y++) {
    for (var x = 0; x < 20; x++) {
      if (mask(output.drivable, (x + 0.5) / 20, 0.5 + (y + 0.5) / 20)) {
        roadPixels++;
      }
    }
  }
  final roadVisible = roadPixels >= 12;
  bool inEgoLane(Rect box) {
    final x = box.center.dx;
    final y = (box.bottom + 0.025).clamp(0.0, 0.99);
    // Sample below the tyres as well as at contact height, bridging gaps in
    // dashed/occluded markings. Project those boundaries back to contact height
    // so a wider lane nearer the camera cannot admit adjacent distant traffic.
    final lefts = <Offset>[], rights = <Offset>[];
    for (final dy in [-0.015, 0.0, 0.015, 0.045, 0.075, 0.105, 0.135]) {
      final row = (y + dy).clamp(0.0, 0.99);
      double? left, right;
      for (var column = 1; column < 199; column++) {
        final laneX = column / 200;
        if (!mask(output.lanes, laneX, row)) continue;
        if (laneX < 0.5) {
          left = laneX;
        } else {
          right ??= laneX;
        }
      }
      if (left != null) lefts.add(Offset(left, row));
      if (right != null) rights.add(Offset(right, row));
    }
    var left = _laneBoundaryAt(lefts, y);
    var right = _laneBoundaryAt(rights, y);
    if (left != null &&
        right != null &&
        (right - left < 0.08 || right - left > 0.85)) {
      // Inconsistent markings do not establish a usable lane pair.
      left = null;
      right = null;
    }
    double laneLeft, laneRight;
    if (left != null && right != null) {
      laneLeft = left - 0.01;
      laneRight = right + 0.01;
    } else {
      // Perspective narrows the fallback for distant vehicles. A single known
      // boundary still excludes traffic beyond it, even without its partner.
      final halfWidth = (0.08 + (y - 0.4) * 0.32).clamp(0.08, 0.24);
      laneLeft = math.max(0.5 - halfWidth, (left ?? 0) - 0.01);
      laneRight = math.min(0.5 + halfWidth, (right ?? 1) + 0.01);
    }
    if (x < laneLeft || x > laneRight) return false;
    final overlap = math.max(
      0.0,
      math.min(box.right, laneRight) - math.max(box.left, laneLeft),
    );
    // A neighbouring car can overlap our lane at its edge. Require most of its
    // box inside the corridor before considering it our lead (including cut-ins).
    if (overlap < box.width * 0.6) return false;
    // Vehicles occlude the road mask. Look just below and beside their tyres,
    // rather than requiring their body to be classified as drivable surface.
    final shoulder = (box.width * 0.35).clamp(0.025, 0.08);
    for (final dx in [-shoulder, 0.0, shoulder]) {
      for (final dy in [0.015, 0.04, 0.08, 0.12]) {
        if (mask(
          output.drivable,
          (x + dx).clamp(0.0, 1.0),
          (box.bottom + dy).clamp(0.0, 0.99),
        )) {
          return true;
        }
      }
    }
    return false;
  }

  return RoadObservation(
    timestamp: frame.timestamp,
    roadVisible: roadVisible,
    vehicles: [
      for (final detection in kept)
        RoadVehicleObservation(
          detection: detection,
          inEgoLane: inEgoLane(detection.normalizedBox),
          distanceMeters: metricVehicleDepth(
            output.depth,
            output.confidence,
            frame.depthLayout,
            detection.normalizedBox,
          ),
        ),
    ],
  );
}

// Estimate a boundary at tyre height from nearby markings. Median slopes and
// projections tolerate a stray mask pixel without widening the entire lane.
double? _laneBoundaryAt(List<Offset> samples, double y) {
  if (samples.isEmpty) return null;
  final slopes = <double>[];
  for (var i = 0; i < samples.length; i++) {
    for (var j = i + 1; j < samples.length; j++) {
      final dy = samples[j].dy - samples[i].dy;
      if (dy.abs() >= 0.03) {
        slopes.add((samples[j].dx - samples[i].dx) / dy);
      }
    }
  }
  final slope = slopes.isEmpty ? 0.0 : _median(slopes);
  return _median([
    for (final sample in samples) sample.dx + (y - sample.dy) * slope,
  ]).clamp(0.0, 1.0);
}

// Nonmaximum suppression only removes duplicate detections within this frame.
double _boxIntersectionOverUnion(Rect a, Rect b) {
  final overlap = a.intersect(b);
  if (overlap.width <= 0 || overlap.height <= 0) return 0;
  final intersection = overlap.width * overlap.height;
  return intersection /
      (a.width * a.height + b.width * b.height - intersection);
}

// Take an interior patch to avoid background road/sky pixels. Confidence is
// UniDepth's relative uncertainty signal, not a calibrated probability: require
// finite positive values, then use spatial depth consistency as the quality gate.
double? metricVehicleDepth(
  Float32List depth,
  Float32List confidence,
  ModelLetterbox layout,
  Rect box,
) {
  if (box.left <= 0.005 ||
      box.top <= 0.005 ||
      box.right >= 0.995 ||
      box.bottom >= 0.995 ||
      box.width <= 0 ||
      box.height <= 0) {
    return null;
  }
  final from = layout.toModel(
    Offset(box.left + box.width * 0.25, box.top + box.height * 0.3),
  );
  final to = layout.toModel(
    Offset(box.right - box.width * 0.25, box.bottom - box.height * 0.2),
  );
  final x0 = from.dx.ceil().clamp(0, layout.width - 1),
      x1 = to.dx.floor().clamp(0, layout.width - 1);
  final y0 = from.dy.ceil().clamp(0, layout.height - 1),
      y1 = to.dy.floor().clamp(0, layout.height - 1);
  if (x1 - x0 < 2 ||
      y1 - y0 < 2 ||
      depth.length != layout.width * layout.height ||
      confidence.length != depth.length) {
    return null;
  }
  final values = <double>[];
  var count = 0;
  final step = math.max(1, math.min(x1 - x0, y1 - y0) ~/ 20);
  for (var y = y0; y <= y1; y += step) {
    for (var x = x0; x <= x1; x += step) {
      count++;
      final index = y * layout.width + x;
      final value = depth[index];
      if (value.isFinite &&
          value >= 1 &&
          value <= 150 &&
          confidence[index].isFinite &&
          confidence[index] > 0) {
        values.add(value);
      }
    }
  }
  if (values.length < 9 || values.length < count * 0.8) return null;
  values.sort();
  final median = _quantile(values, 0.5);
  if ((_quantile(values, 0.75) - _quantile(values, 0.25)) / median > 0.3) {
    return null;
  }
  return median;
}

double _median(List<double> values) {
  values.sort();
  return _quantile(values, 0.5);
}

double _quantile(List<double> sorted, double quantile) {
  final index = (sorted.length - 1) * quantile;
  final lower = index.floor(), upper = index.ceil();
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}
