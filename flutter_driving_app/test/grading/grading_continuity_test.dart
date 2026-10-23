// Verifies that GPS and motion-sensor gaps do not create or inflate violations.

import 'package:flutter_driving_app/widgets/grading/speed_grading_service.dart';
import 'package:flutter_driving_app/widgets/grading/smoothness_grading_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 18, 10);

  void speed(SpeedGradingService service, int second) => service.addSample(
    speedMph: 30,
    speedLimitMph: 25,
    speedingThresholdMph: 5,
    timestamp: start.add(Duration(seconds: second)),
    latitude: 40,
    longitude: -75,
    roadName: 'Main Street',
  );

  void motion(SmoothnessGradingService service, int ms, [double g = 1]) =>
      service.addSample(
        forwardG: g,
        lateralG: 0,
        latitude: 40,
        longitude: -75,
        timestamp: start.add(Duration(milliseconds: ms)),
      );

  test('a GPS outage cannot confirm speeding from isolated fixes', () {
    final service = SpeedGradingService();
    for (final second in [0, 1, 61]) {
      speed(service, second);
    }
    service.finalizeTrip();
    expect(service.grade, 100);
    expect(service.violations, isEmpty);
  });

  test(
    'GPS outages retain earlier penalties and restart grace without merging',
    () {
      final service = SpeedGradingService();
      for (var second = 0; second <= 10; second++) {
        speed(service, second);
      }
      for (var second = 71; second <= 78; second++) {
        speed(service, second);
      }
      service.finalizeTrip();
      expect(service.grade, 93);
      expect(service.violations, hasLength(2));
      expect(
        service.violations.first.endTime,
        start.add(const Duration(seconds: 10)),
      );
      expect(
        service.violations.last.startTime,
        start.add(const Duration(seconds: 71)),
      );
      expect(service.totalSpeedingDuration, const Duration(seconds: 7));
    },
  );

  test('five seconds is the inclusive GPS continuity boundary', () {
    final continuous = SpeedGradingService();
    for (final second in [0, 5, 10]) {
      speed(continuous, second);
    }
    expect(continuous.grade, 95);
    final interrupted = SpeedGradingService();
    for (final second in [0, 6, 11]) {
      speed(interrupted, second);
    }
    expect(interrupted.grade, 100);
  });

  test('separated motion impulses cannot confirm a sustained maneuver', () {
    final service = SmoothnessGradingService();
    motion(service, 0);
    motion(service, 60000);
    service.finalizeTrip();
    expect(service.acceleratingGrade, 100);
    expect(service.violationsFor(SmoothnessCategory.accelerating), isEmpty);
  });

  test('motion outages close confirmed violations at the last sample', () {
    final service = SmoothnessGradingService();
    for (var ms = 0; ms <= 400; ms += 20) {
      motion(service, ms);
    }
    final beforeGap = service.acceleratingGrade;
    motion(service, 2000, 0);
    expect(service.acceleratingGrade, beforeGap);
    expect(
      service.violationsFor(SmoothnessCategory.accelerating).single.endTime,
      start.add(const Duration(milliseconds: 400)),
    );
    for (var ms = 2020; ms <= 2440; ms += 20) {
      motion(service, ms);
    }
    service.finalizeTrip();
    expect(
      service.violationsFor(SmoothnessCategory.accelerating),
      hasLength(2),
    );
  });

  test('250 milliseconds is the inclusive motion continuity boundary', () {
    final continuous = SmoothnessGradingService();
    for (final ms in [0, 250, 500]) {
      motion(continuous, ms);
    }
    continuous.finalizeTrip();
    expect(continuous.acceleratingGrade, lessThan(100));
    final interrupted = SmoothnessGradingService();
    for (final ms in [0, 251, 502]) {
      motion(interrupted, ms);
    }
    interrupted.finalizeTrip();
    expect(interrupted.acceleratingGrade, 100);
  });

  test(
    'duplicate and out-of-order motion samples cannot confirm a candidate',
    () {
      final service = SmoothnessGradingService();
      for (final ms in [100, 100, 50, 300]) {
        motion(service, ms);
      }
      service.finalizeTrip();
      expect(service.acceleratingGrade, 100);
    },
  );
}
