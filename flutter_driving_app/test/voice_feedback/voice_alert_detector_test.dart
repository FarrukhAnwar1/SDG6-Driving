// Tests Live Voice Feedback onset detection against the real graders: one
// alert per episode, nothing during grace or confirmation windows, merged
// smoothness spikes not re-announced, and per-mode gating.
import 'package:flutter/widgets.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_driving_app/widgets/grading/focused_driving_grading_service.dart';
import 'package:flutter_driving_app/widgets/grading/smoothness_grading_service.dart';
import 'package:flutter_driving_app/widgets/grading/speed_grading_service.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_alerts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);
  late DateTime now;
  late SpeedGradingService speed;
  late SmoothnessGradingService smoothness;
  late FocusedDrivingGradingService focus;
  late FollowingDistanceMonitoringService following;
  late VoiceAlertDetector detector;

  void build(DrivingMode mode) {
    now = start;
    speed = SpeedGradingService();
    smoothness = SmoothnessGradingService();
    focus = FocusedDrivingGradingService();
    following = FollowingDistanceMonitoringService(
      drivingMode: mode,
      clock: () => now,
    )..resume();
    detector = VoiceAlertDetector(
      drivingMode: mode,
      speedGrading: speed,
      smoothnessGrading: smoothness,
      focusedDrivingGrading: focus,
      followingDistanceMonitoring: following,
    );
  }

  setUp(() => build(DrivingMode.normal));

  // One GPS fix at [second]; returns the alerts detected right after it.
  List<VoiceAlert> gps(int second, {double mph = 31}) {
    now = start.add(Duration(seconds: second));
    speed.addSample(
      speedMph: mph,
      speedLimitMph: 25,
      speedingThresholdMph: 5,
      timestamp: now,
      latitude: 40,
      longitude: -75,
      roadName: 'Test Road',
    );
    return detector.detectNewAlerts();
  }

  // One camera frame plus its GPS fix at [second], 1 s headway at 30 mph.
  List<VoiceAlert> follow(int second) {
    now = start.add(Duration(seconds: second));
    following.updatePosition(
      speedMph: 30,
      latitude: 40,
      longitude: -75,
      timestamp: now,
    );
    following.addMeasurement(
      FollowingDistanceMeasurement(
        timestamp: now,
        status: FollowingDistanceStatus.tracking,
        distanceMeters: 13.4112,
        leadVehicleId: 'lead',
      ),
    );
    return detector.detectNewAlerts();
  }

  // Feeds 20 ms sensor samples for [duration] from [from]; returns every alert
  // detected along the way.
  List<VoiceAlert> sensors(
    DateTime from,
    Duration duration, {
    double forwardG = 0,
    double lateralG = 0,
  }) {
    final alerts = <VoiceAlert>[];
    for (
      var time = from;
      time.isBefore(from.add(duration));
      time = time.add(const Duration(milliseconds: 20))
    ) {
      smoothness.addSample(
        forwardG: forwardG,
        lateralG: lateralG,
        latitude: 40,
        longitude: -75,
        timestamp: time,
      );
      alerts.addAll(detector.detectNewAlerts());
    }
    return alerts;
  }

  test('phrases are distinct, short and contain no numbers', () {
    final phrases = VoiceAlert.values.map((alert) => alert.phrase).toList();
    expect(phrases.toSet(), hasLength(VoiceAlert.values.length));
    for (final phrase in phrases) {
      expect(phrase.split(' ').length, lessThanOrEqualTo(7), reason: phrase);
      expect(phrase, isNot(matches(RegExp(r'\d'))));
    }
  });

  test('cooldowns are at least as long as the graders\' merge windows', () {
    expect(
      VoiceAlert.speeding.cooldown,
      greaterThanOrEqualTo(SpeedGradingService.violationMergeWindow),
    );
    for (final alert in [
      VoiceAlert.harshBraking,
      VoiceAlert.harshTurning,
      VoiceAlert.harshAccelerating,
    ]) {
      expect(
        alert.cooldown,
        greaterThanOrEqualTo(SmoothnessGradingService.violationCooldown),
      );
    }
  });

  group('speeding', () {
    test('one alert at the first charged fix, none during grace', () {
      for (var second = 0; second <= 5; second++) {
        expect(gps(second), isEmpty, reason: 'second $second');
      }
      expect(gps(6), [VoiceAlert.speeding]);
      for (var second = 7; second <= 40; second++) {
        expect(gps(second), isEmpty, reason: 'second $second');
      }
    });

    test('a new streak is a new onset', () {
      for (var second = 0; second <= 7; second++) {
        gps(second);
      }
      expect(gps(8, mph: 25), isEmpty);
      for (var second = 9; second <= 14; second++) {
        expect(gps(second), isEmpty, reason: 'second $second');
      }
      expect(gps(15), [VoiceAlert.speeding]);
    });

    test('still alerts once the grade is zero', () {
      for (var second = 0; second <= 60; second++) {
        gps(second, mph: 60);
      }
      expect(speed.grade, 0);
      gps(61, mph: 25);
      for (var second = 62; second <= 67; second++) {
        expect(gps(second, mph: 60), isEmpty);
      }
      expect(gps(68, mph: 60), [VoiceAlert.speeding]);
    });
  });

  group('smoothness', () {
    test('a confirmed spike alerts once per category', () {
      final alerts = sensors(start, const Duration(seconds: 1), forwardG: -0.8);
      expect(alerts, [VoiceAlert.harshBraking]);
      expect(
        sensors(
          start.add(const Duration(seconds: 1)),
          const Duration(seconds: 1),
          forwardG: 0.8,
        ),
        [VoiceAlert.harshAccelerating],
      );
      expect(
        sensors(
          start.add(const Duration(seconds: 2)),
          const Duration(seconds: 1),
          lateralG: -0.8,
        ),
        [VoiceAlert.harshTurning],
      );
    });

    test('a short jolt never alerts', () {
      expect(
        sensors(start, const Duration(milliseconds: 300), forwardG: -0.9),
        isEmpty,
      );
      expect(
        sensors(
          start.add(const Duration(milliseconds: 300)),
          const Duration(seconds: 2),
        ),
        isEmpty,
      );
      expect(smoothness.violationCountFor(SmoothnessCategory.braking), 0);
    });

    test('a spike merged into the previous violation is not re-announced', () {
      var time = start;
      List<VoiceAlert> feed(Duration duration, {double forwardG = 0}) {
        final alerts = sensors(time, duration, forwardG: forwardG);
        time = time.add(duration);
        return alerts;
      }

      expect(feed(const Duration(seconds: 1), forwardG: -0.8), [
        VoiceAlert.harshBraking,
      ]);
      expect(feed(const Duration(seconds: 2)), isEmpty);
      // Within the 5 s cooldown of the previous violation ending
      expect(feed(const Duration(seconds: 1), forwardG: -0.8), isEmpty);
      expect(smoothness.violationCountFor(SmoothnessCategory.braking), 1);
      // Well outside the cooldown: a separate violation
      expect(feed(const Duration(seconds: 7)), isEmpty);
      expect(feed(const Duration(seconds: 1), forwardG: -0.8), [
        VoiceAlert.harshBraking,
      ]);
    });
  });

  group('focus', () {
    void awayWhileMoving(int fromSecond, int toSecond) {
      focus.updateLiveState(
        speedMph: 30,
        latitude: 40,
        longitude: -75,
        timestamp: start.add(Duration(seconds: fromSecond)),
      );
      focus.handleLifecycleStateChange(
        AppLifecycleState.paused,
        start.add(Duration(seconds: fromSecond)),
      );
      expect(detector.detectNewAlerts(), isEmpty);
      focus.handleLifecycleStateChange(
        AppLifecycleState.resumed,
        start.add(Duration(seconds: toSecond)),
      );
    }

    test('alerts on return after a graded away period', () {
      awayWhileMoving(0, 2);
      expect(detector.detectNewAlerts(), [VoiceAlert.focus]);
      expect(detector.detectNewAlerts(), isEmpty);
    });

    test('Navigation and Pocket never alert for focus', () {
      for (final mode in [DrivingMode.navigation, DrivingMode.pocket]) {
        build(mode);
        awayWhileMoving(0, 2);
        expect(focus.violationCount, 1);
        expect(detector.detectNewAlerts(), isEmpty);
      }
    });
  });

  group('following distance', () {
    for (final mode in [DrivingMode.normal, DrivingMode.navigation]) {
      test('${mode.apiValue} alerts once, after grace', () {
        build(mode);
        for (var second = 0; second <= 5; second++) {
          expect(follow(second), isEmpty, reason: 'second $second');
        }
        expect(follow(6), [VoiceAlert.followingDistance]);
        for (var second = 7; second <= 16; second++) {
          expect(follow(second), isEmpty, reason: 'second $second');
        }
      });
    }

    test('Pocket never alerts for following distance', () {
      build(DrivingMode.pocket);
      for (var second = 0; second <= 16; second++) {
        expect(follow(second), isEmpty);
      }
    });
  });

  test('alerts that start together come out in priority order', () {
    for (var second = 0; second <= 5; second++) {
      gps(second);
      follow(second);
    }
    now = start.add(const Duration(seconds: 6));
    speed.addSample(
      speedMph: 31,
      speedLimitMph: 25,
      speedingThresholdMph: 5,
      timestamp: now,
      latitude: 40,
      longitude: -75,
      roadName: 'Test Road',
    );
    expect(follow(6), [VoiceAlert.followingDistance, VoiceAlert.speeding]);
  });

  test('nothing that happened before the detector existed is announced', () {
    for (var second = 0; second <= 7; second++) {
      gps(second);
    }
    expect(speed.isPenalizing, isTrue);
    detector = VoiceAlertDetector(
      drivingMode: DrivingMode.normal,
      speedGrading: speed,
      smoothnessGrading: smoothness,
      focusedDrivingGrading: focus,
      followingDistanceMonitoring: following,
    );
    expect(gps(8), isEmpty);
  });
}
