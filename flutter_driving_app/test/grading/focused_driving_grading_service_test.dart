// Tests focus grading when the app is backgrounded before or during movement.

import 'package:flutter/widgets.dart';
import 'package:flutter_driving_app/widgets/grading/focused_driving_grading_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 18, 10);
  late FocusedDrivingGradingService service;

  setUp(() => service = FocusedDrivingGradingService());

  void sample(double speed, int second) => service.updateLiveState(
    speedMph: speed,
    latitude: 40 + second / 10000,
    longitude: -75,
    timestamp: start.add(Duration(seconds: second)),
  );

  test('movement after backgrounding starts at the moving GPS fix', () {
    sample(0, 0);
    service.handleLifecycleStateChange(AppLifecycleState.paused, start);
    sample(30, 20);
    sample(35, 22);
    service.handleLifecycleStateChange(
      AppLifecycleState.resumed,
      start.add(const Duration(seconds: 24)),
    );
    expect(service.violations, hasLength(1));
    final violation = service.violations.single;
    expect(violation.startTime, start.add(const Duration(seconds: 20)));
    expect(violation.duration, const Duration(seconds: 4));
    expect(violation.speedAtStartMph, 30);
    expect(violation.latitude, 40.002);
    expect(service.grade, 86);
  });

  test('stationary background periods do not count as violations', () {
    sample(0, 0);
    service.handleLifecycleStateChange(AppLifecycleState.paused, start);
    sample(2, 20);
    service.handleLifecycleStateChange(
      AppLifecycleState.resumed,
      start.add(const Duration(minutes: 1)),
    );
    expect(service.violations, isEmpty);
    expect(service.grade, 100);
  });

  test('movement in the foreground does not start an away period', () {
    sample(0, 0);
    service.handleLifecycleStateChange(AppLifecycleState.paused, start);
    service.handleLifecycleStateChange(
      AppLifecycleState.resumed,
      start.add(const Duration(seconds: 1)),
    );
    sample(40, 2);
    service.finalizeTrip();
    expect(service.violations, isEmpty);
  });

  test('successive away lifecycle states preserve the original start', () {
    sample(30, 0);
    service.handleLifecycleStateChange(AppLifecycleState.inactive, start);
    service.handleLifecycleStateChange(
      AppLifecycleState.paused,
      start.add(const Duration(seconds: 1)),
    );
    sample(40, 2);
    service.handleLifecycleStateChange(
      AppLifecycleState.resumed,
      start.add(const Duration(seconds: 3)),
    );
    expect(service.violations.single.startTime, start);
    expect(service.violations.single.duration, const Duration(seconds: 3));
  });
}
