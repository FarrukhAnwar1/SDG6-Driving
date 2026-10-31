// Tests the read-only "currently costing points" following-distance signal
// that Live Voice Feedback uses to time following-distance alerts.

import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_grading_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);

  void sample(
    FollowingDistanceGradingService service,
    int second, {
    double headway = 1,
  }) => service.addSample(
    speedMph: 30,
    distanceMeters: 30 * 0.44704 * headway,
    timestamp: start.add(Duration(seconds: second)),
    latitude: 40,
    longitude: -75,
    leadVehicleId: 'lead',
  );

  test('false through grace, true once charged, false after the streak', () {
    final service = FollowingDistanceGradingService();
    for (var second = 0; second <= 5; second++) {
      sample(service, second);
      expect(service.isPenalizing, isFalse, reason: 'second $second');
    }
    sample(service, 6);
    expect(service.isPenalizing, isTrue);
    expect(service.grade, lessThan(100));
    sample(service, 7, headway: 2);
    expect(service.isPenalizing, isFalse);
    for (var second = 8; second <= 13; second++) {
      sample(service, second);
      expect(service.isPenalizing, isFalse, reason: 'second $second');
    }
    sample(service, 14);
    expect(service.isPenalizing, isTrue);
    service.finalizeTrip();
    expect(service.isPenalizing, isFalse);
  });

  test('reading it does not change grading', () {
    final observed = FollowingDistanceGradingService();
    final unobserved = FollowingDistanceGradingService();
    for (var second = 0; second <= 20; second++) {
      final headway = second % 9 < 7 ? 1.0 : 2.0;
      sample(observed, second, headway: headway);
      observed.isPenalizing;
      sample(unobserved, second, headway: headway);
    }
    observed.finalizeTrip();
    unobserved.finalizeTrip();
    expect(observed.grade, unobserved.grade);
    expect(observed.violations.length, unobserved.violations.length);
  });

  group('monitoring pass-through', () {
    late DateTime now;

    FollowingDistanceMonitoringService monitor(DrivingMode mode) {
      now = start;
      return FollowingDistanceMonitoringService(
        drivingMode: mode,
        clock: () => now,
      )..resume();
    }

    void drive(FollowingDistanceMonitoringService service, int second) {
      now = start.add(Duration(seconds: second));
      service.updatePosition(
        speedMph: 30,
        latitude: 40,
        longitude: -75,
        timestamp: now,
      );
      service.addMeasurement(
        FollowingDistanceMeasurement(
          timestamp: now,
          status: FollowingDistanceStatus.tracking,
          distanceMeters: 13.4112,
          leadVehicleId: 'lead',
        ),
      );
    }

    for (final mode in [DrivingMode.normal, DrivingMode.navigation]) {
      test('${mode.apiValue} reports charging after grace and on pause', () {
        final service = monitor(mode);
        for (var second = 0; second <= 5; second++) {
          drive(service, second);
          expect(service.isPenalizing, isFalse, reason: 'second $second');
        }
        drive(service, 6);
        expect(service.isPenalizing, isTrue);
        service.pause();
        expect(service.isPenalizing, isFalse);
      });
    }

    test('Pocket is never charging', () {
      final service = monitor(DrivingMode.pocket);
      for (var second = 0; second <= 10; second++) {
        drive(service, second);
      }
      expect(service.isPenalizing, isFalse);
    });
  });
}
