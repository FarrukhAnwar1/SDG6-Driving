// Tests GPS and camera synchronization, driving modes, and grading continuity.

import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import '../fixtures/road_vision_fixtures.dart';
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
      expect(service.grade, closeTo(98, 0.00001));
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
    expect(service.grade, closeTo(98, 0.00001));
    service.resume();
    now = start.add(const Duration(seconds: 11));
    frame();
    expect(service.status, FollowingDistanceStatus.unavailable);
    drive(12, 18);
    service.finalizeTrip();
    expect(service.grade, closeTo(96, 0.00001));
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
      expect(service.grade, closeTo(98, 0.00001));
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
    expect(service.grade, closeTo(98, 0.00001));
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
    expect(service.grade, closeTo(98, 0.00001));
    expect(service.violations, hasLength(1));
  });

  test('finalization ignores callbacks and attempts to resume', () {
    drive(0, 6);
    service.finalizeTrip();
    service.resume();
    drive(7, 20);
    service.finalizeTrip();
    expect(service.grade, closeTo(98, 0.00001));
    expect(service.violations, hasLength(1));
    expect(service.isActive, isFalse);
  });

  test('learned metric depth preserves a safe gap at one FPS', () {
    final estimator = VehicleDistanceEstimator();
    for (var second = 0; second <= 12; second++) {
      now = start.add(Duration(seconds: second));
      position();
      service.addMeasurement(
        estimator.estimate(
          roadScene(now, vehicles: [roadVehicle(distance: 45)]),
        ),
      );
    }
    expect(service.status, FollowingDistanceStatus.tracking);
    expect(service.headwaySeconds, closeTo(45 / 13.4112, 1e-9));
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test('isolated accepted sightings cannot combine into a violation', () {
    final estimator = VehicleDistanceEstimator();
    for (var second = 0; second <= 12; second++) {
      now = start.add(Duration(seconds: second));
      position();
      service.addMeasurement(
        estimator.estimate(
          roadScene(
            now,
            vehicles: second.isEven
                ? [roadVehicle(confidence: 0.25, distance: 13.4112)]
                : [],
          ),
        ),
      );
      expect(service.headwaySeconds, second.isEven ? closeTo(1, 1e-9) : isNull);
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test(
    'the first accepted sighting starts a full five-second grace period',
    () {
      final estimator = VehicleDistanceEstimator();
      for (var second = 0; second <= 5; second++) {
        now = start.add(Duration(seconds: second));
        position();
        service.addMeasurement(
          estimator.estimate(
            roadScene(now, vehicles: [roadVehicle(distance: 13.4112)]),
          ),
        );
      }
      expect(service.grade, 100);
      now = start.add(const Duration(seconds: 6));
      position();
      service.addMeasurement(
        estimator.estimate(
          roadScene(now, vehicles: [roadVehicle(distance: 13.4112)]),
        ),
      );
      service.finalizeTrip();
      expect(service.grade, closeTo(98, 1e-9));
      expect(service.violations.single.startTime, start);
      expect(
        service.violations.single.penalizedDuration,
        const Duration(seconds: 1),
      );
    },
  );

  test('continuation-only confidence cannot start grading without a lead', () {
    final estimator = VehicleDistanceEstimator();
    for (var second = 0; second <= 10; second++) {
      now = start.add(Duration(seconds: second));
      position();
      service.addMeasurement(
        estimator.estimate(
          roadScene(
            now,
            vehicles: [roadVehicle(confidence: 0.15, distance: 13.4112)],
          ),
        ),
      );
      expect(service.headwaySeconds, isNull);
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test(
    'a delayed model result uses capture-time speed rather than arrival speed',
    () {
      position();
      now = start.add(const Duration(seconds: 1));
      service.updatePosition(
        speedMph: 60,
        latitude: 40,
        longitude: -75,
        timestamp: now,
      );
      now = start.add(const Duration(milliseconds: 1500));
      service.addMeasurement(
        FollowingDistanceMeasurement(
          timestamp: start,
          status: FollowingDistanceStatus.tracking,
          distanceMeters: 26.8224,
          leadVehicleId: 'lead',
        ),
      );
      expect(service.headwaySeconds, closeTo(2, 1e-9));
      // Normal inference latency is not an outage when results keep arriving.
      now = start.add(const Duration(milliseconds: 2600));
      service.checkForInterruption();
      expect(service.status, FollowingDistanceStatus.tracking);
      now = start.add(const Duration(milliseconds: 3100));
      position();
      service.checkForInterruption();
      expect(service.status, FollowingDistanceStatus.unavailable);
    },
  );

  test('in-flight processing has five seconds while GPS stays fresh', () {
    position();
    service.beginMeasurement(start);
    expect(service.status, FollowingDistanceStatus.processing);
    for (var second = 1; second <= 3; second++) {
      now = start.add(Duration(seconds: second));
      position();
      service.checkForInterruption();
      expect(service.status, FollowingDistanceStatus.processing);
    }
    frame(timestamp: start);
    expect(service.status, FollowingDistanceStatus.tracking);
    expect(service.measurementAge, const Duration(seconds: 3));
    expect(service.headwaySeconds, closeTo(1, 1e-9));
  });

  test(
    'unexplained gaps remain interruptions despite the longer result window',
    () {
      for (var capturedSecond = 0; capturedSecond <= 12; capturedSecond += 3) {
        now = start.add(Duration(seconds: capturedSecond));
        position();
        final capturedAt = now;
        for (var offset = 1; offset <= 3; offset++) {
          now = capturedAt.add(Duration(seconds: offset));
          position();
          service.checkForInterruption();
        }
        frame(timestamp: capturedAt);
      }
      service.finalizeTrip();
      expect(service.grade, 100);
      expect(service.violations, isEmpty);
    },
  );

  test('consecutive slow jobs grade at their measured capture cadence', () {
    for (var second = 0; second <= 8; second += 2) {
      now = start.add(Duration(seconds: second));
      position();
      final capturedAt = now;
      service.beginMeasurement(capturedAt);
      for (var offset = 1; offset <= 2; offset++) {
        now = capturedAt.add(Duration(seconds: offset));
        position();
        service.checkForInterruption();
      }
      frame(timestamp: capturedAt);
    }
    service.finalizeTrip();
    expect(service.grade, closeTo(94, 1e-9));
    expect(
      service.violations.single.penalizedDuration,
      const Duration(seconds: 3),
    );
  });

  test('a processing timeout is one outage and a later frame can recover', () {
    position();
    service.beginMeasurement(start);
    for (var second = 1; second <= 7; second++) {
      now = start.add(Duration(seconds: second));
      position();
      service.checkForInterruption();
    }
    expect(service.status, FollowingDistanceStatus.unavailable);
    frame(timestamp: start);
    expect(service.status, FollowingDistanceStatus.unavailable);
    service.beginMeasurement(now);
    final capturedAt = now;
    now = now.add(const Duration(seconds: 1));
    position();
    frame(timestamp: capturedAt);
    expect(service.status, FollowingDistanceStatus.tracking);
    expect(service.grade, 100);
  });

  test('a recent no-vehicle result stays visible while the next job runs', () {
    position();
    frame(status: FollowingDistanceStatus.noVehicle);
    now = start.add(const Duration(seconds: 1));
    position();
    service.beginMeasurement(now);
    expect(service.status, FollowingDistanceStatus.noVehicle);
    now = start.add(const Duration(seconds: 4));
    position();
    service.checkForInterruption();
    expect(service.status, FollowingDistanceStatus.noVehicle);
  });

  test('a late result cannot revive a streak after GPS becomes invalid', () {
    position();
    now = start.add(const Duration(seconds: 1));
    service.invalidatePosition();
    position();
    frame(timestamp: start);
    expect(service.status, FollowingDistanceStatus.unavailable);
    expect(service.headwaySeconds, isNull);
    frame();
    expect(service.status, FollowingDistanceStatus.tracking);
  });

  test(
    'watchdog lets fresh delayed results recover after one camera outage',
    () {
      drive(0, 6);
      now = start.add(const Duration(seconds: 8));
      position();
      service.checkForInterruption();
      expect(service.status, FollowingDistanceStatus.unavailable);
      // A second watchdog tick must not advance the cutoff past this new frame.
      // At 1.5s latency every otherwise-fresh result used to remain rejected.
      now = start.add(const Duration(seconds: 9));
      position();
      service.checkForInterruption();
      now = start.add(const Duration(milliseconds: 9500));
      frame(timestamp: start.add(const Duration(seconds: 8)));
      expect(service.status, FollowingDistanceStatus.tracking);
      expect(service.headwaySeconds, closeTo(1, 1e-9));
      expect(service.grade, closeTo(98, 1e-9));
    },
  );
}
