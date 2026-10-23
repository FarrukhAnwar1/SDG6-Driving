// Tests GPS and camera synchronization, driving modes, and grading continuity.

import 'dart:ui';

import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_geometry.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);
  late DateTime now;
  late FollowingDistanceMonitoringService service;

  setUp(() {
    now = start;
    service = FollowingDistanceMonitoringService(
      drivingMode: DrivingMode.normal,
      clock: () => now,
    );
    service.resume();
  });

  void position({DateTime? timestamp}) => service.updatePosition(
    speedMph: 30,
    latitude: 40,
    longitude: -75,
    timestamp: timestamp ?? now,
  );

  void frame({
    DateTime? timestamp,
    FollowingDistanceStatus status = FollowingDistanceStatus.tracking,
  }) => service.addMeasurement(
    FollowingDistanceMeasurement(
      timestamp: timestamp ?? now,
      status: status,
      distanceMeters: 13.4112,
      leadVehicleId: 'lead',
    ),
  );

  void drive(int from, int through) {
    for (var second = from; second <= through; second++) {
      now = start.add(Duration(seconds: second));
      position();
      frame();
    }
  }

  for (final mode in [DrivingMode.normal, DrivingMode.navigation]) {
    test('${mode.apiValue} monitors distance using fresh GPS and frames', () {
      service = FollowingDistanceMonitoringService(
        drivingMode: mode,
        clock: () => now,
      );
      service.resume();
      drive(0, 6);
      expect(service.grade, closeTo(95, 0.00001));
      expect(service.headwaySeconds, closeTo(1, 0.00001));
      service.finalizeTrip();
      expect(service.violations, hasLength(1));
    });
  }

  test(
    'Pocket never starts monitoring and returns null without violations',
    () {
      service = FollowingDistanceMonitoringService(
        drivingMode: DrivingMode.pocket,
        clock: () => now,
      );
      service.resume();
      drive(0, 10);
      service.finalizeTrip();
      expect(service.isActive, isFalse);
      expect(service.grade, isNull);
      expect(service.violations, isEmpty);
    },
  );

  test('camera observations cannot grade without a trusted position', () {
    for (var second = 0; second <= 10; second++) {
      now = start.add(Duration(seconds: second));
      frame();
    }
    expect(service.grade, 100);
    expect(service.status, FollowingDistanceStatus.unavailable);
  });

  test('fresh frames cannot extend a stale GPS speed/location', () {
    position();
    for (var second = 0; second <= 10; second++) {
      now = start.add(Duration(seconds: second));
      frame();
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test('background/resume resets grace and requires a fresh GPS fix', () {
    drive(0, 6);
    service.pause();
    drive(7, 10);
    expect(service.grade, closeTo(95, 0.00001));
    service.resume();
    now = start.add(const Duration(seconds: 11));
    frame();
    expect(service.status, FollowingDistanceStatus.unavailable);
    drive(12, 18);
    service.finalizeTrip();
    expect(service.grade, closeTo(90, 0.00001));
    expect(service.violations, hasLength(2));
    expect(
      service.violations.first.endTime,
      start.add(const Duration(seconds: 6)),
    );
    expect(
      service.violations.last.startTime,
      start.add(const Duration(seconds: 12)),
    );
  });

  test(
    'camera failure and unreliable observations interrupt at the last frame',
    () {
      drive(0, 6);
      service.cameraUnavailable();
      expect(
        service.violations.single.endTime,
        start.add(const Duration(seconds: 6)),
      );
      drive(7, 11);
      now = start.add(const Duration(seconds: 12));
      position();
      frame(status: FollowingDistanceStatus.unreliable);
      drive(13, 17);
      service.finalizeTrip();
      expect(service.grade, closeTo(95, 0.00001));
      expect(service.violations, hasLength(1));
    },
  );

  test('watchdog closes an event when camera frames cease entirely', () {
    drive(0, 6);
    now = start.add(const Duration(seconds: 8));
    position();
    service.checkForInterruption();
    expect(service.status, FollowingDistanceStatus.unavailable);
    expect(service.headwaySeconds, isNull);
    expect(
      service.violations.single.endTime,
      start.add(const Duration(seconds: 6)),
    );
    drive(9, 13);
    service.finalizeTrip();
    expect(service.grade, closeTo(95, 0.00001));
  });

  test('stale and future frames cannot supply a new streak', () {
    for (var second = 0; second <= 10; second++) {
      now = start.add(Duration(seconds: second));
      position();
      frame(timestamp: now.subtract(const Duration(seconds: 2)));
      frame(timestamp: now.add(const Duration(seconds: 20)));
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test('invalid GPS breaks the streak even when camera frames continue', () {
    drive(0, 6);
    now = start.add(const Duration(seconds: 7));
    service.invalidatePosition();
    frame();
    drive(8, 12);
    service.finalizeTrip();
    expect(service.grade, closeTo(95, 0.00001));
    expect(service.violations, hasLength(1));
  });

  test('finalization ignores callbacks and attempts to resume', () {
    drive(0, 6);
    service.finalizeTrip();
    service.resume();
    drive(7, 20);
    service.finalizeTrip();
    expect(service.grade, closeTo(95, 0.00001));
    expect(service.violations, hasLength(1));
    expect(service.isActive, isFalse);
  });

  test(
    'portrait geometry preserves a safe gap with a small car above mid-frame',
    () {
      const geometry = RoadCameraGeometry(
        focalLength: 6,
        imagePlaneWidth: 6,
        imagePlaneHeight: 4.5,
      );
      final focal = geometry.normalizedFocalLengthFor(const Size(480, 640))!;
      final estimator = VehicleDistanceEstimator(normalizedFocalLength: focal);
      // A 1.8m-wide car at 45m spans about 5.33% of this portrait frame. At
      // 30 mph this is a safe 3.36s; the old 60-degree guess reports 2.18s.
      final detection = VehicleDetection(
        label: 'car',
        confidence: 0.4,
        normalizedBox: Rect.fromCenter(
          center: const Offset(0.5, 0.37),
          width: 1.8 * focal / 45,
          height: 0.1,
        ),
      );
      for (var index = 0; index <= 60; index++) {
        now = start.add(Duration(milliseconds: index * 200));
        position();
        service.addMeasurement(
          estimator.estimate(detections: [detection], timestamp: now),
        );
      }
      expect(service.status, FollowingDistanceStatus.tracking);
      expect(service.headwaySeconds, closeTo(45 / 13.4112, 1e-9));
      service.finalizeTrip();
      expect(service.grade, 100);
      expect(service.violations, isEmpty);
    },
  );

  test(
    'isolated weak sightings never penalize or reuse a previous distance',
    () {
      final estimator = VehicleDistanceEstimator(normalizedFocalLength: 1);
      const detection = VehicleDetection(
        label: 'car',
        confidence: 0.4,
        normalizedBox: Rect.fromLTRB(0.4, 0.3, 0.6, 0.45),
      );
      for (var index = 0; index <= 60; index++) {
        now = start.add(Duration(milliseconds: index * 200));
        position();
        service.addMeasurement(
          estimator.estimate(
            detections: index.isEven ? [detection] : [],
            timestamp: now,
          ),
        );
        expect(service.headwaySeconds, isNull);
      }
      service.finalizeTrip();
      expect(service.grade, 100);
      expect(service.violations, isEmpty);
    },
  );

  test(
    'confirmation time is excluded from a confirmed unsafe vehicles grace period',
    () {
      final estimator = VehicleDistanceEstimator(normalizedFocalLength: 1);
      final width = 1.8 / 13.4112;
      final detection = VehicleDetection(
        label: 'car',
        confidence: 0.4,
        normalizedBox: Rect.fromCenter(
          center: const Offset(0.5, 0.4),
          width: width,
          height: 0.1,
        ),
      );
      for (var index = 0; index <= 27; index++) {
        now = start.add(Duration(milliseconds: index * 200));
        position();
        service.addMeasurement(
          estimator.estimate(detections: [detection], timestamp: now),
        );
      }
      expect(service.grade, 100);
      now = start.add(const Duration(milliseconds: 5600));
      position();
      service.addMeasurement(
        estimator.estimate(detections: [detection], timestamp: now),
      );
      service.finalizeTrip();
      expect(service.grade, closeTo(99, 1e-9));
      expect(
        service.violations.single.startTime,
        start.add(const Duration(milliseconds: 400)),
      );
      expect(
        service.violations.single.penalizedDuration,
        const Duration(milliseconds: 200),
      );
    },
  );
}
