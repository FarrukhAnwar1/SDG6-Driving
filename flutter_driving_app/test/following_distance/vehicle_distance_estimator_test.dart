// Tests vehicle filtering, confirmation, distance estimates, and target continuity.

import 'dart:ui';

import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  VehicleDistanceEstimator estimator() =>
      VehicleDistanceEstimator.fromHorizontalFieldOfView(60);
  final start = DateTime.utc(2026, 10, 22, 10);
  const car = VehicleDetection(
    label: 'car',
    confidence: 0.9,
    normalizedBox: Rect.fromLTRB(0.4, 0.4, 0.6, 0.8),
  );

  test('pinhole geometry uses class width and configurable camera FOV', () {
    final estimate = estimator().estimate(detections: [car], timestamp: start);
    expect(estimate.status, FollowingDistanceStatus.tracking);
    expect(estimate.distanceMeters, closeTo(7.79423, 0.0001));
    final widerLens = VehicleDistanceEstimator.fromHorizontalFieldOfView(90);
    expect(
      widerLens.estimate(detections: [car], timestamp: start).distanceMeters,
      closeTo(4.5, 0.0001),
    );
    final truck = VehicleDetection(
      label: 'truck',
      confidence: 0.9,
      normalizedBox: car.normalizedBox,
    );
    expect(
      estimator()
          .estimate(detections: [truck], timestamp: start)
          .distanceMeters,
      closeTo(10.8253, 0.0001),
    );
  });

  test('selects the nearest central vehicle and ignores adjacent traffic', () {
    const adjacent = VehicleDetection(
      label: 'car',
      confidence: 0.99,
      normalizedBox: Rect.fromLTRB(0.02, 0.3, 0.45, 0.95),
    );
    const far = VehicleDetection(
      label: 'car',
      confidence: 0.99,
      normalizedBox: Rect.fromLTRB(0.46, 0.4, 0.54, 0.55),
    );
    final measurement = estimator().estimate(
      detections: [adjacent, far, car],
      timestamp: start,
    );
    expect(measurement.distanceMeters, closeTo(7.79423, 0.0001));
  });

  test('empty scenes and non-vehicles produce no distance', () {
    for (final detections in [
      <VehicleDetection>[],
      [
        VehicleDetection(
          label: 'person',
          confidence: 0.99,
          normalizedBox: car.normalizedBox,
        ),
      ],
    ]) {
      final measurement = estimator().estimate(
        detections: detections,
        timestamp: start,
      );
      expect(measurement.status, FollowingDistanceStatus.noVehicle);
      expect(measurement.distanceMeters, isNull);
    }
  });

  test('clipped, tiny and non-finite boxes are ungraded', () {
    for (final detection in [
      VehicleDetection(
        label: 'car',
        confidence: double.nan,
        normalizedBox: car.normalizedBox,
      ),
      const VehicleDetection(
        label: 'car',
        confidence: 0.99,
        normalizedBox: Rect.fromLTRB(0, 0.4, 0.9, 0.8),
      ),
      const VehicleDetection(
        label: 'car',
        confidence: 0.99,
        normalizedBox: Rect.fromLTRB(0.4, 0.4, 0.6, 1),
      ),
      const VehicleDetection(
        label: 'car',
        confidence: 0.99,
        normalizedBox: Rect.fromLTRB(0.5, 0.4, 0.51, 0.8),
      ),
      const VehicleDetection(
        label: 'car',
        confidence: 0.99,
        normalizedBox: Rect.fromLTRB(double.nan, 0.4, 0.6, 0.8),
      ),
      const VehicleDetection(
        label: 'car',
        confidence: 0.99,
        normalizedBox: Rect.fromLTRB(0.4, 0.8, 0.6, 0.5),
      ),
    ]) {
      final measurement = estimator().estimate(
        detections: [detection],
        timestamp: start,
      );
      expect(measurement.status, FollowingDistanceStatus.unreliable);
      expect(measurement.distanceMeters, isNull);
    }
  });

  test(
    'stable boxes retain identity, a different vehicle restarts tracking',
    () {
      final estimator = VehicleDistanceEstimator.fromHorizontalFieldOfView(60);
      final first = estimator.estimate(detections: [car], timestamp: start);
      final second = estimator.estimate(
        detections: [car],
        timestamp: start.add(const Duration(milliseconds: 200)),
      );
      expect(second.leadVehicleId, first.leadVehicleId);
      final third = estimator.estimate(
        detections: [
          VehicleDetection(
            label: 'bus',
            confidence: 0.99,
            normalizedBox: car.normalizedBox,
          ),
        ],
        timestamp: start.add(const Duration(milliseconds: 400)),
      );
      expect(third.leadVehicleId, isNot(first.leadVehicleId));
    },
  );

  test(
    'loss of sight and long gaps cannot preserve the old vehicle identity',
    () {
      final estimator = VehicleDistanceEstimator.fromHorizontalFieldOfView(60);
      final first = estimator.estimate(detections: [car], timestamp: start);
      estimator.estimate(
        detections: [],
        timestamp: start.add(const Duration(milliseconds: 200)),
      );
      final second = estimator.estimate(
        detections: [car],
        timestamp: start.add(const Duration(milliseconds: 400)),
      );
      expect(second.leadVehicleId, isNot(first.leadVehicleId));
      final third = estimator.estimate(
        detections: [car],
        timestamp: start.add(const Duration(seconds: 3)),
      );
      expect(third.leadVehicleId, isNot(second.leadVehicleId));
    },
  );

  test('an implausible distance jump is rejected and resets tracking', () {
    final estimator = VehicleDistanceEstimator.fromHorizontalFieldOfView(60);
    estimator.estimate(detections: [car], timestamp: start);
    const jump = VehicleDetection(
      label: 'car',
      confidence: 0.99,
      normalizedBox: Rect.fromLTRB(0.3, 0.4, 0.7, 0.8),
    );
    final measurement = estimator.estimate(
      detections: [jump],
      timestamp: start.add(const Duration(milliseconds: 200)),
    );
    expect(measurement.status, FollowingDistanceStatus.unreliable);
    expect(measurement.distanceMeters, isNull);
  });

  test('a lead vehicle above the old fixed horizon is eligible', () {
    final result = estimator().estimate(
      detections: const [
        VehicleDetection(
          label: 'car',
          confidence: 0.8,
          normalizedBox: Rect.fromLTRB(0.46, 0.3, 0.54, 0.42),
        ),
      ],
      timestamp: start,
    );
    expect(result.status, FollowingDistanceStatus.tracking);
    expect(result.distanceMeters, closeTo(19.4856, 0.0001));
  });

  test('moderate confidence requires repeated sightings before grading', () {
    final subject = estimator();
    final detection = VehicleDetection(
      label: 'car',
      confidence: 0.35,
      normalizedBox: car.normalizedBox,
    );
    for (final ms in [0, 200]) {
      final result = subject.estimate(
        detections: [detection],
        timestamp: start.add(Duration(milliseconds: ms)),
      );
      expect(result.status, FollowingDistanceStatus.confirming);
      expect(result.distanceMeters, isNull);
      expect(result.leadVehicleId, isNull);
    }
    final confirmed = subject.estimate(
      detections: [detection],
      timestamp: start.add(const Duration(milliseconds: 400)),
    );
    expect(confirmed.status, FollowingDistanceStatus.tracking);
    expect(confirmed.distanceMeters, closeTo(7.79423, 0.0001));
    final next = subject.estimate(
      detections: [detection],
      timestamp: start.add(const Duration(milliseconds: 600)),
    );
    expect(next.leadVehicleId, confirmed.leadVehicleId);
  });

  test('isolated weak detections cannot be combined across missing frames', () {
    final subject = estimator();
    for (var index = 0; index < 20; index++) {
      final result = subject.estimate(
        detections: index.isEven
            ? [
                VehicleDetection(
                  label: 'car',
                  confidence: 0.35,
                  normalizedBox: car.normalizedBox,
                ),
              ]
            : [],
        timestamp: start.add(Duration(milliseconds: index * 200)),
      );
      expect(result.distanceMeters, isNull);
      expect(result.status, isNot(FollowingDistanceStatus.tracking));
    }
  });

  test(
    'subthreshold and adjacent clipped vehicles do not obscure an empty lane',
    () {
      final result = estimator().estimate(
        detections: [
          VehicleDetection(
            label: 'car',
            confidence: 0.29,
            normalizedBox: car.normalizedBox,
          ),
          const VehicleDetection(
            label: 'truck',
            confidence: 0.99,
            normalizedBox: Rect.fromLTRB(0, 0.3, 0.4, 1),
          ),
        ],
        timestamp: start,
      );
      expect(result.status, FollowingDistanceStatus.noVehicle);
      expect(result.distanceMeters, isNull);
    },
  );

  test('three-frame median suppresses a single oversized bounding box', () {
    final subject = estimator();
    for (var index = 0; index < 3; index++) {
      subject.estimate(
        detections: [car],
        timestamp: start.add(Duration(milliseconds: index * 200)),
      );
    }
    final result = subject.estimate(
      detections: const [
        VehicleDetection(
          label: 'car',
          confidence: 0.9,
          normalizedBox: Rect.fromLTRB(0.36, 0.4, 0.64, 0.8),
        ),
      ],
      timestamp: start.add(const Duration(milliseconds: 600)),
    );
    expect(result.status, FollowingDistanceStatus.tracking);
    expect(result.distanceMeters, closeTo(7.79423, 0.0001));
  });

  test('a new estimator cannot reuse the previous camera target identity', () {
    final first = estimator().estimate(detections: [car], timestamp: start);
    final rotated = estimator().estimate(detections: [car], timestamp: start);
    expect(rotated.leadVehicleId, isNot(first.leadVehicleId));
  });
}
