// Unit tests for the SpeedGradingService
//
// This suite verifies the core scoring logic for driver speed evaluation,
// ensuring the application correctly processes the speed limit data returned
// from the self-hosted Python API. It validates server-provided tolerances, the
// 5-second grace window, and severity-scaled deductions for sustained
// speeding. It also covers grouped violations, plus edge cases like
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
    double? speedingThresholdMph = 5,
    required DateTime timestamp,
    String? roadName,
  }) => addSample(
    speedMph: speedMph,
    speedLimitMph: speedLimitMph,
    speedingThresholdMph: speedingThresholdMph,
    timestamp: timestamp,
    latitude: _latitude,
    longitude: _longitude,
    roadName: roadName,
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

    for (final threshold in [5.0, 10.0, 15.0]) {
      test('uses a $threshold mph tolerance including its boundary', () {
        final service = SpeedGradingService();
        for (final seconds in [0, 10]) {
          service.addSampleAt(
            speedMph: 25 + threshold - 0.1,
            speedLimitMph: 25,
            speedingThresholdMph: threshold,
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        expect(service.grade, 100);
        expect(service.violationCount, 0);

        for (final seconds in [11, 21]) {
          service.addSampleAt(
            speedMph: 25 + threshold,
            speedLimitMph: 25,
            speedingThresholdMph: threshold,
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        service.finalizeTrip();
        expect(service.grade, 95);
        expect(service.violationCount, 1);
        expect(
          service.violations.single.startTime,
          start.add(const Duration(seconds: 11)),
        );
      });
    }

    test(
      'a wider tolerance ends a streak and gives the next one fresh grace',
      () {
        final service = SpeedGradingService();
        for (final seconds in [0, 10]) {
          service.addSampleAt(
            speedMph: 30,
            speedLimitMph: 25,
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        service.addSampleAt(
          speedMph: 30,
          speedLimitMph: 25,
          speedingThresholdMph: 10,
          timestamp: start.add(const Duration(seconds: 11)),
        );
        expect(service.grade, 95);
        expect(service.violationCount, 1);

        for (final seconds in [20, 24, 30]) {
          service.addSampleAt(
            speedMph: 35,
            speedLimitMph: 25,
            speedingThresholdMph: 10,
            timestamp: start.add(Duration(seconds: seconds)),
          );
          expect(service.grade, seconds == 30 ? 90 : 95);
        }
        service.finalizeTrip();
        expect(service.violationCount, 2);
      },
    );

    test(
      'a missing tolerance ends a streak without charging the unknown gap',
      () {
        final service = SpeedGradingService();
        for (final seconds in [0, 10, 20, 60, 64]) {
          service.addSampleAt(
            speedMph: 35,
            speedLimitMph: 25,
            speedingThresholdMph: seconds == 20 ? null : 10,
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        service.finalizeTrip();
        expect(service.grade, 95);
        expect(service.violationCount, 1);
        expect(
          service.violations.single.endTime,
          start.add(const Duration(seconds: 10)),
        );
      },
    );

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
        service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
        service.addSampleAt(
          speedMph: 70,
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
        service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);

        // Right at the 5s grace boundary so no points lost yet
        service.addSampleAt(
          speedMph: 70,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 5)),
        );
        expect(service.grade, 100);

        // 5 more seconds past the grace window so 5 points lost
        service.addSampleAt(
          speedMph: 70,
          speedLimitMph: 65,
          timestamp: start.add(const Duration(seconds: 10)),
        );
        expect(service.grade, 95);
      },
    );

    test('a violation is recorded once the driver drops under threshold, '
        'excluding the grace period from the penalized duration', () {
      final service = SpeedGradingService();
      service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 70,
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
          speedingThresholdMph: 5,
          timestamp: start,
          latitude: 40.1,
          longitude: -75.1,
        );
        // Faster later in the streak, and from a different place, so only the
        // peak speed should move and the coordinates should stay at the start
        service.addSample(
          speedMph: 85,
          speedLimitMph: 65,
          speedingThresholdMph: 5,
          timestamp: start.add(const Duration(seconds: 6)),
          latitude: 40.2,
          longitude: -75.2,
        );
        service.addSample(
          speedMph: 80,
          speedLimitMph: 65,
          speedingThresholdMph: 5,
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
      service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 70,
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
        speedMph: 70,
        speedLimitMph: 65,
        timestamp: secondStart,
      );
      service.addSampleAt(
        speedMph: 70,
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
      service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 70,
        speedLimitMph: 65,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      expect(service.grade, 95);

      // Speed limit data becomes unavailable (such as off the mapped roads)
      service.addSampleAt(
        speedMph: 70,
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
        service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
        service.addSampleAt(
          speedMph: 70,
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
      service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 70,
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
      service.addSampleAt(speedMph: 70, speedLimitMph: 65, timestamp: start);
      service.addSampleAt(
        speedMph: 70,
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

    test('penalties rise continuously with speed beyond the tolerance', () {
      for (final threshold in [5.0, 10.0, 15.0]) {
        for (final excess in [0.0, 2.5, 5.0, 10.0]) {
          final service = SpeedGradingService();
          for (final seconds in [0, 10]) {
            service.addSampleAt(
              speedMph: 25 + threshold + excess,
              speedLimitMph: 25,
              speedingThresholdMph: threshold,
              timestamp: start.add(Duration(seconds: seconds)),
            );
          }
          service.finalizeTrip();
          expect(service.grade, 100 - 5 * (1 + excess / 5));
          expect(service.totalSpeedingDuration, const Duration(seconds: 5));
        }
      }
    });

    test('changing speed changes the rate without recharging earlier time', () {
      final service = SpeedGradingService();
      for (final seconds in [0, 5, 7]) {
        service.addSampleAt(
          speedMph: 30,
          speedLimitMph: 25,
          timestamp: start.add(Duration(seconds: seconds)),
        );
      }
      expect(service.grade, 98);
      service.addSampleAt(
        speedMph: 40,
        speedLimitMph: 25,
        timestamp: start.add(const Duration(seconds: 9)),
      );
      expect(service.grade, 92);
      service.addSampleAt(
        speedMph: 30,
        speedLimitMph: 25,
        timestamp: start.add(const Duration(seconds: 10)),
      );
      expect(service.grade, 91);
    });

    test('exactly five seconds of speeding does not record a violation', () {
      final service = SpeedGradingService();
      for (final seconds in [0, 5]) {
        service.addSampleAt(
          speedMph: 40,
          speedLimitMph: 25,
          timestamp: start.add(Duration(seconds: seconds)),
        );
      }
      service.finalizeTrip();
      expect(service.grade, 100);
      expect(service.violations, isEmpty);
    });

    test(
      'a brief lookup gap groups same-road violations without grading it',
      () {
        final service = SpeedGradingService();
        for (final seconds in [0, 10]) {
          service.addSample(
            speedMph: 30,
            speedLimitMph: 25,
            speedingThresholdMph: 5,
            timestamp: start.add(Duration(seconds: seconds)),
            latitude: 40.1,
            longitude: -75.1,
            roadName: 'Main Street',
          );
        }
        for (final seconds in [11, 12, 13]) {
          service.addSampleAt(
            speedMph: 100,
            speedLimitMph: null,
            speedingThresholdMph: null,
            timestamp: start.add(Duration(seconds: seconds)),
          );
          expect(service.grade, 95);
        }
        for (final seconds in [14, 24]) {
          service.addSampleAt(
            speedMph: 40,
            speedLimitMph: 25,
            timestamp: start.add(Duration(seconds: seconds)),
            roadName: ' MAIN   Street ',
          );
        }
        service.finalizeTrip();
        service.finalizeTrip();

        expect(service.grade, 80);
        expect(service.violationCount, 1);
        final violation = service.violations.single;
        expect(violation.startTime, start);
        expect(violation.endTime, start.add(const Duration(seconds: 24)));
        expect(violation.roadName, 'Main Street');
        expect(violation.latitude, 40.1);
        expect(violation.longitude, -75.1);
        expect(violation.peakSpeedMph, 40);
        expect(violation.penalizedDuration, const Duration(seconds: 10));
        expect(service.totalSpeedingDuration, const Duration(seconds: 10));
      },
    );

    test('successive nearby streaks remain one violation', () {
      final service = SpeedGradingService();
      for (final firstSecond in [0, 12, 24]) {
        for (final offset in [0, 10, 11]) {
          service.addSampleAt(
            speedMph: offset == 11 ? 25 : 30,
            speedLimitMph: 25,
            roadName: 'Main Street',
            timestamp: start.add(Duration(seconds: firstSecond + offset)),
          );
        }
        expect(service.violationCount, 1);
      }
      expect(service.grade, 85);
      expect(
        service.violations.single.endTime,
        start.add(const Duration(seconds: 34)),
      );
      expect(service.totalSpeedingDuration, const Duration(seconds: 15));
    });

    for (final gap in [10, 11]) {
      test('same-road streaks $gap seconds apart respect the merge window', () {
        final service = SpeedGradingService();
        for (final seconds in [0, 10, 11, 10 + gap, 20 + gap]) {
          service.addSampleAt(
            speedMph: 30,
            speedLimitMph: seconds == 11 ? null : 25,
            roadName: seconds == 11 ? null : 'Main Street',
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        service.finalizeTrip();
        expect(service.grade, 90);
        expect(service.violationCount, gap == 10 ? 1 : 2);
        expect(service.totalSpeedingDuration, const Duration(seconds: 10));
      });
    }

    test('turning onto another road starts a separate violation', () {
      final service = SpeedGradingService();
      for (final seconds in [0, 10, 11, 21]) {
        service.addSampleAt(
          speedMph: 30,
          speedLimitMph: 25,
          roadName: seconds < 11 ? 'Main Street' : 'Oak Avenue',
          timestamp: start.add(Duration(seconds: seconds)),
        );
      }
      service.finalizeTrip();
      expect(service.grade, 90);
      expect(service.violationCount, 2);
      expect(service.violations.map((v) => v.roadName), [
        'Main Street',
        'Oak Avenue',
      ]);
    });

    for (final otherRoadLimit in [25.0, null]) {
      test(
        'an intervening road with limit $otherRoadLimit prevents merging',
        () {
          final service = SpeedGradingService();
          for (final seconds in [0, 10, 11, 12, 22]) {
            service.addSampleAt(
              speedMph: seconds == 11 ? 20 : 30,
              speedLimitMph: seconds == 11 ? otherRoadLimit : 25,
              roadName: seconds == 11 ? 'Oak Avenue' : 'Main Street',
              timestamp: start.add(Duration(seconds: seconds)),
            );
          }
          service.finalizeTrip();
          expect(service.violationCount, 2);
        },
      );
    }

    test('unnamed roads are not assumed to be the same road across a gap', () {
      final service = SpeedGradingService();
      for (final seconds in [0, 10, 11, 12, 22]) {
        service.addSampleAt(
          speedMph: 30,
          speedLimitMph: seconds == 11 ? null : 25,
          roadName: seconds == 11 ? null : ' ',
          timestamp: start.add(Duration(seconds: seconds)),
        );
      }
      service.finalizeTrip();
      expect(service.violationCount, 2);
    });

    test('reset clears pending road grouping and timing state', () {
      final service = SpeedGradingService();
      for (var trip = 0; trip < 2; trip++) {
        for (final seconds in [0, 10, 11]) {
          service.addSampleAt(
            speedMph: 30,
            speedLimitMph: seconds == 11 ? null : 25,
            roadName: seconds == 11 ? null : 'Main Street',
            timestamp: start.add(Duration(seconds: seconds)),
          );
        }
        service.finalizeTrip();
        expect(service.violationCount, 1);
        expect(service.grade, 95);
        service.reset();
      }
    });

    test('duplicate and out-of-order fixes cannot inflate penalties', () {
      final service = SpeedGradingService();
      for (final seconds in [0, 10, 10, 9, 11]) {
        service.addSampleAt(
          speedMph: 30,
          speedLimitMph: 25,
          roadName: 'Main Street',
          timestamp: start.add(Duration(seconds: seconds)),
        );
      }
      service.finalizeTrip();
      expect(service.grade, 94);
      expect(service.totalSpeedingDuration, const Duration(seconds: 6));
    });
  });
}
