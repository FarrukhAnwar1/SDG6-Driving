// Checks real model tensor contracts, padding reversal and metric-depth gates.

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_output.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 23);
  final detectorLayout = ModelLetterbox(480, 640, detectorSide, detectorSide);
  final depthLayout = ModelLetterbox(480, 640, depthWidth, depthHeight);
  late Float32List detections, road, lanes, depth, confidence;
  final area = detectorSide * detectorSide;

  setUp(() {
    detections = Float32List(25200 * 6);
    road = Float32List(area * 2)..fillRange(area, area * 2, 1);
    lanes = Float32List(area * 2)..fillRange(0, area, 1);
    depth = Float32List(depthWidth * depthHeight)
      ..fillRange(0, depthWidth * depthHeight, 26.8224);
    confidence = Float32List(depth.length)..fillRange(0, depth.length, 0.2);
  });
  void detection(
    int index,
    Rect box, {
    double objectness = 0.9,
    double classScore = 0.8,
  }) {
    final center = detectorLayout.toModel(box.center);
    detections.setRange(index * 6, index * 6 + 6, [
      center.dx,
      center.dy,
      box.width * detectorLayout.imageWidth,
      box.height * detectorLayout.imageHeight,
      objectness,
      classScore,
    ]);
  }

  void maskPatch(Float32List scores, Rect patch, double value) {
    final from = detectorLayout.toModel(patch.topLeft);
    final to = detectorLayout.toModel(patch.bottomRight);
    for (var y = from.dy.ceil(); y <= to.dy.floor(); y++) {
      for (var x = from.dx.ceil(); x <= to.dx.floor(); x++) {
        scores[area + y * detectorSide + x] = value;
      }
    }
  }

  void laneLine(
    double intercept,
    double slope, {
    double from = 0.02,
    double to = 0.98,
  }) {
    for (var row = (from * 640).ceil(); row < (to * 640).floor(); row++) {
      final y = row / 640;
      final x = intercept + slope * y;
      maskPatch(lanes, Rect.fromLTRB(x - 0.004, y, x + 0.004, y + 1 / 640), 2);
    }
  }

  RoadModelOutput output() => RoadModelOutput(
    frame: PreparedRoadFrame(
      timestamp: start,
      detector: Float32List(0),
      depth: Float32List(0),
      detectorLayout: detectorLayout,
      depthLayout: depthLayout,
    ),
    detections: detections,
    drivable: road,
    lanes: lanes,
    depth: depth,
    confidence: confidence,
    intrinsics: Float32List.fromList([500, 0, 196, 0, 500, 266, 0, 0, 1]),
  );

  test(
    'YOLOP objectness/class scores, NMS and portrait padding map correctly',
    () {
      const box = Rect.fromLTRB(0.4, 0.3, 0.6, 0.6);
      detection(0, box);
      detection(1, box, objectness: 0.8);
      detection(2, const Rect.fromLTRB(0.75, 0.3, 0.9, 0.6));
      final decoded = decodeRoadModels(output());
      expect(decoded.vehicles, hasLength(2));
      final lead = decoded.vehicles.first;
      expect(lead.detection.normalizedBox.left, closeTo(0.4, 1e-6));
      expect(lead.detection.normalizedBox.bottom, closeTo(0.6, 1e-6));
      expect(lead.detection.confidence, closeTo(0.72, 1e-6));
      expect(lead.distanceMeters, closeTo(26.8224, 1e-4));
      expect(lead.inEgoLane, isTrue);
      expect(decoded.vehicles.last.inEgoLane, isFalse);
    },
  );

  test(
    'lane segmentation can follow a road corridor away from image center',
    () {
      detection(0, const Rect.fromLTRB(0.64, 0.3, 0.76, 0.65));
      for (final x in [0.45, 0.8]) {
        final column = detectorLayout.toModel(Offset(x, 0)).dx.floor();
        for (var y = 0; y < detectorSide; y++) {
          for (var dx = -2; dx <= 2; dx++) {
            lanes[area + y * detectorSide + column + dx] = 2;
          }
        }
      }
      expect(decodeRoadModels(output()).vehicles.single.inEgoLane, isTrue);
    },
  );

  test('the fallback narrows for distant traffic and allows near offsets', () {
    detection(0, const Rect.fromLTRB(0.45, 0.25, 0.55, 0.4));
    detection(1, const Rect.fromLTRB(0.6, 0.25, 0.7, 0.4));
    detection(2, const Rect.fromLTRB(0.76, 0.3, 0.88, 0.6));
    detection(3, const Rect.fromLTRB(0.25, 0.55, 0.45, 0.9));
    detection(4, const Rect.fromLTRB(0.55, 0.55, 0.75, 0.9));
    final decoded = decodeRoadModels(output());
    expect(decoded.vehicles.map((v) => v.inEgoLane), [
      true,
      false,
      false,
      true,
      true,
    ]);
  });

  test('lane boundary jitter does not discard a vehicle on the boundary', () {
    detection(0, const Rect.fromLTRB(0.53, 0.3, 0.65, 0.6));
    for (final x in [0.4, 0.6]) {
      maskPatch(lanes, Rect.fromLTRB(x - 0.004, 0.01, x + 0.004, 0.99), 2);
    }
    expect(decodeRoadModels(output()).vehicles.single.inEgoLane, isTrue);
  });

  test('a car mostly beyond a visible boundary cannot become the lead', () {
    detection(0, const Rect.fromLTRB(0.57, 0.3, 0.69, 0.6));
    laneLine(0.4, 0);
    laneLine(0.6, 0);
    expect(decodeRoadModels(output()).vehicles.single.inEgoLane, isFalse);
  });

  test('a cut-in qualifies once most of its box enters the lane', () {
    detection(0, const Rect.fromLTRB(0.52, 0.3, 0.64, 0.6));
    laneLine(0.4, 0);
    laneLine(0.6, 0);
    expect(decodeRoadModels(output()).vehicles.single.inEgoLane, isTrue);
  });

  for (final boundary in [0.43, 0.57]) {
    test('a single line at $boundary excludes traffic on its far side', () {
      detection(0, const Rect.fromLTRB(0.45, 0.3, 0.55, 0.6));
      detection(
        1,
        boundary < 0.5
            ? const Rect.fromLTRB(0.3, 0.3, 0.4, 0.6)
            : const Rect.fromLTRB(0.6, 0.3, 0.7, 0.6),
      );
      laneLine(boundary, 0);
      final decoded = decodeRoadModels(output());
      expect(decoded.vehicles.map((v) => v.inEgoLane), [true, false]);
    });
  }

  test('dashed lines below the tyres still exclude adjacent traffic', () {
    detection(0, const Rect.fromLTRB(0.44, 0.3, 0.56, 0.6));
    detection(1, const Rect.fromLTRB(0.6, 0.3, 0.68, 0.6));
    laneLine(0.4, 0, from: 0.69, to: 0.73);
    laneLine(0.58, 0, from: 0.69, to: 0.73);
    final decoded = decodeRoadModels(output());
    expect(decoded.vehicles.map((v) => v.inEgoLane), [true, false]);
  });

  test('converging boundaries are projected to the distant vehicle row', () {
    detection(0, const Rect.fromLTRB(0.45, 0.18, 0.55, 0.4));
    detection(1, const Rect.fromLTRB(0.58, 0.18, 0.66, 0.4));
    // At the tyres the lane is narrow; lower dashed segments are wider.
    laneLine(0.5, -0.2, from: 0.46, to: 0.57);
    laneLine(0.5, 0.2, from: 0.46, to: 0.57);
    final decoded = decodeRoadModels(output());
    expect(decoded.vehicles.map((v) => v.inEgoLane), [true, false]);
  });

  test('a closer adjacent car does not replace the car in our lane', () {
    const leadBox = Rect.fromLTRB(0.43, 0.3, 0.57, 0.6);
    const sideBox = Rect.fromLTRB(0.6, 0.3, 0.7, 0.6);
    detection(0, leadBox);
    detection(1, sideBox, objectness: 0.99, classScore: 0.99);
    laneLine(0.58, 0);
    depth.fillRange(0, depth.length, 40);
    final from = depthLayout.toModel(sideBox.topLeft);
    final to = depthLayout.toModel(sideBox.bottomRight);
    for (var y = from.dy.ceil(); y <= to.dy.floor(); y++) {
      for (var x = from.dx.ceil(); x <= to.dx.floor(); x++) {
        depth[y * depthWidth + x] = 8;
      }
    }
    final decoded = decodeRoadModels(output());
    expect(decoded.vehicles.first.distanceMeters, 8);
    final selected = VehicleDistanceEstimator().estimate(decoded);
    expect(selected.status, FollowingDistanceStatus.tracking);
    expect(selected.distanceMeters, 40);
  });

  test(
    'fragmented road evidence below an occluding vehicle remains usable',
    () {
      road.fillRange(0, road.length, 0);
      maskPatch(road, const Rect.fromLTRB(0.34, 0.7, 0.66, 0.8), 1);
      detection(0, const Rect.fromLTRB(0.4, 0.3, 0.6, 0.6));
      final decoded = decodeRoadModels(output());
      expect(decoded.roadVisible, isTrue);
      expect(decoded.vehicles.single.inEgoLane, isTrue);
    },
  );

  test('road elsewhere cannot substitute for evidence below the vehicle', () {
    maskPatch(road, const Rect.fromLTRB(0.35, 0.6, 0.65, 0.99), 0);
    detection(0, const Rect.fromLTRB(0.4, 0.3, 0.6, 0.6));
    final decoded = decodeRoadModels(output());
    expect(decoded.roadVisible, isTrue);
    expect(decoded.vehicles.single.inEgoLane, isFalse);
  });

  test(
    'weak boxes remain available for matching but very weak boxes are dropped',
    () {
      detection(
        0,
        const Rect.fromLTRB(0.3, 0.3, 0.4, 0.6),
        objectness: 0.15,
        classScore: 1,
      );
      detection(
        1,
        const Rect.fromLTRB(0.6, 0.3, 0.7, 0.6),
        objectness: 0.09,
        classScore: 1,
      );
      final decoded = decodeRoadModels(output());
      expect(decoded.vehicles, hasLength(1));
      expect(decoded.vehicles.single.detection.confidence, closeTo(0.15, 1e-6));
    },
  );

  test('no drivable evidence and missing/invalid tensors cannot be graded', () {
    road.fillRange(0, road.length, 0);
    detection(0, const Rect.fromLTRB(0.4, 0.3, 0.6, 0.6));
    final decoded = decodeRoadModels(output());
    expect(decoded.roadVisible, isFalse);
    expect(decoded.vehicles.single.inEgoLane, isFalse);
    detections = Float32List(6);
    expect(() => decodeRoadModels(output()), throwsFormatException);
  });

  test(
    'metric depth rejects mixed background, nonfinite data and clipped boxes',
    () {
      final layout = ModelLetterbox(20, 20, 20, 20);
      final depth = Float32List(400)..fillRange(0, 400, 40);
      final confidence = Float32List(400)..fillRange(0, 400, 0.01);
      const box = Rect.fromLTRB(0.1, 0.1, 0.9, 0.9);
      expect(metricVehicleDepth(depth, confidence, layout, box), 40);
      expect(
        metricVehicleDepth(
          depth,
          confidence,
          layout,
          const Rect.fromLTRB(0, 0.1, 0.9, 0.9),
        ),
        isNull,
      );
      for (var i = 0; i < depth.length; i++) {
        depth[i] = i.isEven ? 8 : 80;
      }
      expect(metricVehicleDepth(depth, confidence, layout, box), isNull);
      depth.fillRange(0, depth.length, double.nan);
      expect(metricVehicleDepth(depth, confidence, layout, box), isNull);
      depth.fillRange(0, depth.length, 40);
      confidence.fillRange(0, confidence.length, 0);
      expect(metricVehicleDepth(depth, confidence, layout, box), isNull);
    },
  );
}
