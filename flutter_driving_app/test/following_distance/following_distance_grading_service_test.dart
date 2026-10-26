// Tests following-distance thresholds, violation timing, and interruptions.

import 'package:flutter_driving_app/widgets/following_distance/following_distance_grading_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);

  void sample(
    FollowingDistanceGradingService service,
    double seconds, {
    double speed = 30,
    double? headway = 1,
    String vehicle = 'lead',
    double latitude = 40,
    double longitude = -75,
    Duration processingDuration = Duration.zero,
  }) => service.addSample(
    speedMph: speed,
    distanceMeters: headway == null ? null : speed * 0.44704 * headway,
    timestamp: start.add(Duration(milliseconds: (seconds * 1000).round())),
    latitude: latitude,
    longitude: longitude,
    leadVehicleId: vehicle,
    processingDuration: processingDuration,
  );

  void unsafe(FollowingDistanceGradingService service, int through) {
    for (var second = 0; second <= through; second++) {
      sample(service, second.toDouble());
    }
  }

  test('headway threshold scales distance with speed; equality is safe', () {
    for (final speed in [25.0, 30.0, 70.0]) {
      for (final headway in [1.5, 2.0, 3.0]) {
        final service = FollowingDistanceGradingService();
        for (var second = 0; second <= 15; second++) {
          sample(service, second.toDouble(), speed: speed, headway: headway);
        }
        service.finalizeTrip();
        expect(service.grade, 100);
        expect(service.violations, isEmpty);
      }
    }
  });

  test('headways just below 1.5 seconds are penalized after grace', () {
    for (final speed in [25.0, 30.0, 70.0]) {
      final service = FollowingDistanceGradingService();
      for (var second = 0; second <= 6; second++) {
        sample(service, second.toDouble(), speed: speed, headway: 1.49);
      }
      service.finalizeTrip();
      expect(service.grade, closeTo(98.98, 1e-9));
      expect(service.violations, hasLength(1));
    }
  });

  test('25 mph is the inclusive minimum grading speed', () {
    for (final (speed, expectedGrade, violationCount) in [
      (24.9, 100, 0),
      (25.0, 98, 1),
    ]) {
      final service = FollowingDistanceGradingService();
      for (var second = 0; second <= 6; second++) {
        sample(service, second.toDouble(), speed: speed);
      }
      service.finalizeTrip();
      expect(service.grade, closeTo(expectedGrade, 0.00001));
      expect(service.violations, hasLength(violationCount));
    }
  });

  test('grace is neutral and only time after five seconds costs points', () {
    final service = FollowingDistanceGradingService();
    unsafe(service, 5);
    expect(service.grade, 100);
    sample(service, 5.2);
    expect(service.grade, closeTo(99.6, 0.00001));
    sample(service, 6);
    expect(service.grade, closeTo(98, 0.00001));
    service.finalizeTrip();
    final violation = service.violations.single;
    expect(violation.startTime, start);
    expect(violation.endTime, start.add(const Duration(seconds: 6)));
    expect(violation.penalizedDuration, const Duration(seconds: 1));
    expect(violation.minimumHeadwaySeconds, closeTo(1, 0.00001));
    expect(violation.minimumDistanceMeters, closeTo(13.4112, 0.00001));
  });

  test('a grace-only candidate does not become a recorded violation', () {
    final service = FollowingDistanceGradingService();
    unsafe(service, 5);
    service.finalizeTrip();
    expect(service.violations, isEmpty);
  });

  test('shorter headways cost more and safe driving does not regenerate', () {
    final close = FollowingDistanceGradingService();
    final closer = FollowingDistanceGradingService();
    for (var second = 0; second <= 6; second++) {
      sample(close, second.toDouble(), headway: 1);
      sample(closer, second.toDouble(), headway: 0.5);
    }
    expect(close.grade, closeTo(98, 0.00001));
    expect(closer.grade, closeTo(97, 0.00001));
    sample(closer, 7, headway: 1.5);
    sample(closer, 8, headway: 1.5);
    expect(closer.grade, closeTo(97, 0.00001));
    expect(
      closer.violations.single.endTime,
      start.add(const Duration(seconds: 6)),
    );
  });

  test('start coordinates are retained when the vehicle moves', () {
    final service = FollowingDistanceGradingService();
    sample(service, 0);
    for (var second = 1; second <= 6; second++) {
      sample(service, second.toDouble(), latitude: 41, longitude: -76);
    }
    service.finalizeTrip();
    expect(service.violations.single.latitude, 40);
    expect(service.violations.single.longitude, -75);
  });

  test(
    'safe intervals reset grace instead of joining short unsafe streaks',
    () {
      final service = FollowingDistanceGradingService();
      unsafe(service, 4);
      sample(service, 5, headway: 3);
      for (var second = 6; second <= 10; second++) {
        sample(service, second.toDouble());
      }
      service.finalizeTrip();
      expect(service.grade, 100);
      expect(service.violations, isEmpty);
    },
  );

  test('missing, non-finite, zero and negative distances break continuity', () {
    for (final distance in [null, double.nan, double.infinity, 0.0, -2.0]) {
      final service = FollowingDistanceGradingService();
      unsafe(service, 6);
      service.addSample(
        speedMph: 30,
        distanceMeters: distance,
        timestamp: start.add(const Duration(seconds: 7)),
        latitude: 40,
        longitude: -75,
      );
      for (var second = 8; second <= 12; second++) {
        sample(service, second.toDouble());
      }
      service.finalizeTrip();
      expect(service.grade, closeTo(98, 0.00001));
      expect(service.violations, hasLength(1));
      expect(
        service.violations.single.endTime,
        start.add(const Duration(seconds: 6)),
      );
    }
  });

  test(
    'a monitoring gap cannot confirm isolated frames or charge unknown time',
    () {
      final service = FollowingDistanceGradingService();
      unsafe(service, 6);
      for (var second = 60; second <= 66; second++) {
        sample(service, second.toDouble());
      }
      service.finalizeTrip();
      expect(service.grade, closeTo(96, 0.00001));
      expect(service.violations, hasLength(2));
      expect(
        service.violations.first.endTime,
        start.add(const Duration(seconds: 6)),
      );
      expect(
        service.violations.last.startTime,
        start.add(const Duration(seconds: 60)),
      );
    },
  );

  test('a missed one-FPS observation breaks continuity beyond 1500ms', () {
    final service = FollowingDistanceGradingService();
    for (var ms = 0; ms <= 10507; ms += 1501) {
      sample(service, ms / 1000);
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test('one-FPS timing jitter is charged by actual elapsed time', () {
    final service = FollowingDistanceGradingService();
    for (final seconds in [0.0, 1.1, 2.0, 3.1, 4.0, 5.1, 6.0]) {
      sample(service, seconds);
    }
    service.finalizeTrip();
    expect(service.grade, closeTo(98, 1e-9));
    expect(
      service.violations.single.penalizedDuration,
      const Duration(seconds: 1),
    );
  });

  test('1500ms is the inclusive continuity boundary', () {
    final service = FollowingDistanceGradingService();
    for (final seconds in [0.0, 1.5, 3.0, 4.5, 6.0]) {
      sample(service, seconds);
    }
    service.finalizeTrip();
    expect(service.grade, closeTo(98, 1e-9));
  });

  test(
    'missing one scheduled frame restarts grace without charging the gap',
    () {
      final service = FollowingDistanceGradingService();
      unsafe(service, 6);
      for (var second = 8; second <= 13; second++) {
        sample(service, second.toDouble());
      }
      expect(service.grade, closeTo(98, 1e-9));
      sample(service, 14);
      service.finalizeTrip();
      expect(service.grade, closeTo(96, 1e-9));
      expect(service.violations, hasLength(2));
      expect(
        service.violations.first.endTime,
        start.add(const Duration(seconds: 6)),
      );
      expect(
        service.violations.last.startTime,
        start.add(const Duration(seconds: 8)),
      );
    },
  );

  test('duplicates and out-of-order frames cannot double charge', () {
    final service = FollowingDistanceGradingService();
    unsafe(service, 6);
    sample(service, 6);
    sample(service, 2);
    expect(service.grade, closeTo(98, 0.00001));
    sample(service, 7);
    expect(service.grade, closeTo(96, 0.00001));
  });

  test('a slow current job cannot excuse a missed previous observation', () {
    final service = FollowingDistanceGradingService();
    unsafe(service, 6);
    sample(service, 8, processingDuration: const Duration(seconds: 3));
    sample(service, 11, processingDuration: const Duration(seconds: 3));
    expect(service.grade, closeTo(98, 1e-9));
    sample(service, 14, processingDuration: const Duration(seconds: 3));
    service.finalizeTrip();
    expect(service.grade, closeTo(96, 1e-9));
    expect(
      service.violations.first.endTime,
      start.add(const Duration(seconds: 6)),
    );
    expect(
      service.violations.last.startTime,
      start.add(const Duration(seconds: 8)),
    );
  });

  test('a changed lead vehicle gets a fresh grace window', () {
    final service = FollowingDistanceGradingService();
    unsafe(service, 4);
    for (var second = 5; second <= 9; second++) {
      sample(service, second.toDouble(), vehicle: 'cut-in');
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test(
    'stops and invalid speed/location readings never confirm violations',
    () {
      for (final speed in [0.0, 24.9, -1.0, double.nan, double.infinity]) {
        final service = FollowingDistanceGradingService();
        for (var second = 0; second <= 10; second++) {
          sample(service, second.toDouble(), speed: speed);
        }
        service.finalizeTrip();
        expect(service.grade, 100);
        expect(service.violations, isEmpty);
      }
      final service = FollowingDistanceGradingService();
      for (var second = 0; second <= 10; second++) {
        sample(service, second.toDouble(), latitude: double.nan);
      }
      expect(service.grade, 100);
    },
  );

  test(
    'finalization is idempotent, freezes results, and scores stop at zero',
    () {
      final service = FollowingDistanceGradingService();
      unsafe(service, 60);
      service.finalizeTrip();
      expect(service.grade, 0);
      expect(service.violations, hasLength(1));
      sample(service, 61, headway: 3);
      service.finalizeTrip();
      expect(service.grade, 0);
      expect(service.violations, hasLength(1));
      expect(() => service.violations.clear(), throwsUnsupportedError);
    },
  );
}
