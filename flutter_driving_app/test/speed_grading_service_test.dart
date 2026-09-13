// Unit tests for the SpeedGradingService
//
// This suite verifies the core scoring logic for driver speed evaluation,
// ensuring the application correctly processes the speed limit data returned
// from the self-hosted Python API. It validates the 5 MPH buffer, the
// 5-second grace window, and the 1-point-per-second deduction for sustained
// speeding. It also covers the recorded violations, plus edge cases like
// multiple speeding streaks, handling null speed limits, trip finalization,
// and state resets.
// Note: if any constants in SpeedGradingService are changed, these tests
// may need to be updated accordingly.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/widgets/speed_grading_service.dart';

// Coordinates only tag where a violation began, they never affect grading, so
// tests that don't care about them can feed samples from one fixed point.
const double _latitude = 40.0;
const double _longitude = -75.0;

extension _FixedPointSamples on SpeedGradingService {
  void addSampleAt({
    required double speedMph,
    required double? speedLimitMph,
    required DateTime timestamp,
  }) => addSample(
    speedMph: speedMph,
    speedLimitMph: speedLimitMph,
    timestamp: timestamp,
    latitude: _latitude,
    longitude: _longitude,
  );
}

void main() {
  group('SpeedGradingService', () {
    final start = DateTime(2026, 1, 1, 12, 0, 0);

    test('starts at a grade of 100 with no violations', () {
      final service = SpeedGradingService();
      expect(service.grade, 100);
      expect(service.violationCount, 0);
      expect(service.violations, isEmpty);
      expect(service.totalSpeedingDuration, Duration.zero);
    });

    test('driving under the threshold never penalizes the grade', () {
      final service = SpeedGradingService();
      // 65 in a 65 zone: not speeding at all
      service.addSampleAt(speedMph: 65, speedLimitMph: 65, timestamp: start);
      // 68 in a 65 zone: only 3 mph over, below the 5 mph threshold
      service.addSampleAt(
        speedMph: 68,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );

      expect(service.grade, 100);
      expect(service.violationCount, 0);
    });

    test(
      'a brief excursion that never clears the grace window is not penalized',
      () {
        final service = SpeedGradingService();
        service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
        service.addSampleAt(
          speedMph: 80,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 3)),
        );
        // Drops back under the limit before the 5s grace window elapses
        service.addSampleAt(
          speedMph: 60,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 4)),
        );

        expect(service.grade, 100);
        expect(service.violationCount, 0);
        expect(service.violations, isEmpty);
        expect(service.totalSpeedingDuration, Duration.zero);
      },
    );

    test(
      'sustained speeding past the grace window costs 1 point per second over',
      () {
        final service = SpeedGradingService();
        service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);

        // Right at the 5s grace boundary so no points lost yet
        service.addSampleAt(
          speedMph: 80,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 5)),
        );
        expect(service.grade, 100);

        // 5 more seconds past the grace window so 5 points lost
        service.addSampleAt(
          speedMph: 80,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 10)),
        );
        expect(service.grade, 95);
      },
    );

    test('a violation is recorded once the driver drops under threshold, '
        'excluding the grace period from the penalized duration', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      service.addSampleAt(
        speedMph: 60,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 11)),
      );

      expect(service.grade, 95);
      expect(service.violationCount, 1);

      final violation = service.violations.single;
      expect(violation.startTime, start);
      // The streak ends at the last sample that was still speeding, not at the
      // sample that dropped back under the threshold
      expect(violation.endTime, start.add(const Duration(seconds: 10)));
      expect(violation.duration, const Duration(seconds: 10));
      // 10s total streak - 5s grace period = 5s actually penalized
      expect(violation.penalizedDuration, const Duration(seconds: 5));
      expect(service.totalSpeedingDuration, const Duration(seconds: 5));
    });

    test(
      'a violation records where it began, the posted limit and peak speed',
      () {
        final service = SpeedGradingService();
        service.addSample(
          speedMph: 75,
          speedLimitMph: 65,
          timestamp: start,
          latitude: 40.1,
          longitude: -75.1,
        );
        // Faster later in the streak, and from a different place, so only the
        // peak speed should move and the coordinates should stay at the start
        service.addSample(
          speedMph: 85,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 6)),
          latitude: 40.2,
          longitude: -75.2,
        );
        service.addSample(
          speedMph: 80,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 8)),
          latitude: 40.3,
          longitude: -75.3,
        );
        service.finalizeTrip();

        final violation = service.violations.single;
        expect(violation.latitude, 40.1);
        expect(violation.longitude, -75.1);
        expect(violation.speedLimitMph, 65);
        expect(violation.peakSpeedMph, 85);
        expect(violation.peakOverLimitMph, 20);
      },
    );

    test('two separate streaks over threshold count as two violations', () {
      final service = SpeedGradingService();

      // First violation: a 10s sustained streak
      service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      service.addSampleAt(
        speedMph: 60,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 11)),
      );

      // Clean for a while, then a second, separate 10s sustained streak
      final secondStart = start.add(const Duration(minutes: 1));
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: secondStart,
      );
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: secondStart.add(const Duration(seconds: 10)),
      );
      service.addSampleAt(
        speedMph: 60,
        speedLimitMph: 65,
        timestamp: secondStart.add(const Duration(seconds: 11)),
      );

      expect(service.violationCount, 2);
      expect(service.violations[1].startTime, secondStart);
      expect(service.totalSpeedingDuration, const Duration(seconds: 10));
      expect(service.grade, 90);
    });

    test('grade never drops below 0 even for extreme sustained speeding', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 100, speedLimitMph: 65, timestamp: start);
      // Jump straight to 205 secs of speeding which is 200 secs past the grace window,
      // which would be -100 points if the grade weren't clamped
      service.addSampleAt(
        speedMph: 100,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 205)),
      );

      expect(service.grade, 0);
    });

    test('a null speed limit ends the current streak without penalizing', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      expect(service.grade, 95);

      // Speed limit data becomes unavailable (such as off the mapped roads)
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: null,
        timestamp: start.add(const Duration(seconds: 11)),
      );

      expect(service.grade, 95);
      expect(service.violationCount, 1);
    });

    test(
      'finalizeTrip records a streak still in progress when the trip ends',
      () {
        final service = SpeedGradingService();
        service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
        service.addSampleAt(
          speedMph: 80,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 10)),
        );

        // Trip ends mid-violation with no further samples to close it out
        expect(service.violationCount, 0);
        service.finalizeTrip();

        expect(service.violationCount, 1);
        expect(service.totalSpeedingDuration, const Duration(seconds: 5));
      },
    );

    test('regeneration is currently a no-op since regenPointsPerMinute is 0', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      expect(service.grade, 95);

      // 10 clean minutes afterward
      service.addSampleAt(
        speedMph: 60,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(minutes: 10)),
      );

      // If regenPointsPerMinute is ever turned back on, the expected value should too
      expect(service.grade, 95);
    });

    test('reset() restores the initial state', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 80, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 80,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      service.finalizeTrip();
      expect(service.grade, lessThan(100));
      expect(service.violationCount, greaterThan(0));

      service.reset();

      expect(service.grade, 100);
      expect(service.violationCount, 0);
      expect(service.violations, isEmpty);
      expect(service.totalSpeedingDuration, Duration.zero);
    });
  });
}
