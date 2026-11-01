// Tests SpeedGradingService.isPenalizing, the read-only "currently costing
// points" signal that Live Voice Feedback uses to time speeding alerts.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/widgets/grading/speed_grading_service.dart';

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);

  void sample(
    SpeedGradingService service,
    int second, {
    double speed = 31,
    double? limit = 25,
  }) => service.addSample(
    speedMph: speed,
    speedLimitMph: limit,
    speedingThresholdMph: 5,
    timestamp: start.add(Duration(seconds: second)),
    latitude: 40,
    longitude: -75,
    roadName: 'Test Road',
  );

  test('false through grace, true from the first charged fix', () {
    final service = SpeedGradingService();
    for (var second = 0; second <= 5; second++) {
      sample(service, second);
      expect(service.isPenalizing, isFalse, reason: 'second $second');
    }
    expect(service.grade, 100);
    sample(service, 6);
    expect(service.isPenalizing, isTrue);
    expect(service.grade, lessThan(100));
    sample(service, 7);
    expect(service.isPenalizing, isTrue);
  });

  test('ends with the streak and restarts only after fresh grace', () {
    final service = SpeedGradingService();
    for (var second = 0; second <= 7; second++) {
      sample(service, second);
    }
    expect(service.isPenalizing, isTrue);
    sample(service, 8, speed: 25);
    expect(service.isPenalizing, isFalse);
    for (var second = 9; second <= 14; second++) {
      sample(service, second);
      expect(service.isPenalizing, isFalse, reason: 'second $second');
    }
    sample(service, 15);
    expect(service.isPenalizing, isTrue);
  });

  test('a lost limit, a GPS gap and finalizeTrip all clear it', () {
    final service = SpeedGradingService();
    for (var second = 0; second <= 7; second++) {
      sample(service, second);
    }
    sample(service, 8, limit: null);
    expect(service.isPenalizing, isFalse);

    for (var second = 9; second <= 15; second++) {
      sample(service, second);
    }
    expect(service.isPenalizing, isTrue);
    sample(service, 30);
    expect(service.isPenalizing, isFalse);

    for (var second = 31; second <= 37; second++) {
      sample(service, second);
    }
    expect(service.isPenalizing, isTrue);
    service.finalizeTrip();
    expect(service.isPenalizing, isFalse);
  });

  test('stays true at a grade of zero', () {
    final service = SpeedGradingService();
    for (var second = 0; second <= 200; second++) {
      sample(service, second, speed: 60);
    }
    expect(service.grade, 0);
    expect(service.isPenalizing, isTrue);
  });

  test('reading it does not change grading', () {
    final observed = SpeedGradingService();
    final unobserved = SpeedGradingService();
    for (var second = 0; second <= 20; second++) {
      final speed = second % 9 < 7 ? 33.0 : 20.0;
      sample(observed, second, speed: speed);
      observed.isPenalizing;
      sample(unobserved, second, speed: speed);
    }
    observed.finalizeTrip();
    unobserved.finalizeTrip();
    expect(observed.grade, unobserved.grade);
    expect(observed.violationCount, unobserved.violationCount);
    expect(observed.totalSpeedingDuration, unobserved.totalSpeedingDuration);
  });
}
