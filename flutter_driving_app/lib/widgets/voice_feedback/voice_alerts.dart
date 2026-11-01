// The spoken Live Voice Feedback alerts and how their onsets are detected.
//
// ONSET RULE:
// An alert fires when a category STARTS costing points, never before (no
// warnings during grace windows) and never as a repeating reminder:
// - Speeding / following distance: the grader's read-only isPenalizing
//   signal turns from false to true, i.e. the first charged sample after
//   that grader's grace window.
// - Braking / accelerating / turning: violationCountFor goes up, i.e. a spike
//   has just survived the 350 ms confirmation window. A spike merged into the
//   previous violation (within its cooldown) does not raise the count.
// - Focus: violationCount goes up, which only happens when the driver
//   returns to the app after being away while moving.
// Alerts still fire once a category's grade has reached 0.
//
// MODES:
// Focus is only detected when the mode tracks focus (Regular) and following
// distance only when it tracks following distance (Regular, Navigation).
//
// The detector only reads grader state. It never changes grades, violations,
// or grading behavior.
import '../driving/driving_mode.dart';
import '../following_distance/following_distance_monitoring_service.dart';
import '../grading/focused_driving_grading_service.dart';
import '../grading/smoothness_grading_service.dart';
import '../grading/speed_grading_service.dart';

// Declared in priority order: when several alerts are waiting, the earliest
// one here is spoken first.
enum VoiceAlert {
  followingDistance,
  speeding,
  harshBraking,
  harshTurning,
  harshAccelerating,
  focus,
}

extension VoiceAlertDetails on VoiceAlert {
  // Detection can flap (any interruption gives a fresh 5 s grace window), so
  // this caps repeats at two per minute.
  static const Duration followingDistanceCooldown = Duration(seconds: 30);

  // Several times SpeedGradingService.violationMergeWindow (10 s). Merged
  // streaks, GPS gaps and speed-limit refreshes can each restart grace.
  static const Duration speedingCooldown = Duration(seconds: 30);

  // Several times SmoothnessGradingService.violationCooldown (5 s), applied
  // per category. Also covers a new violation right after a sensor gap.
  static const Duration smoothnessCooldown = Duration(seconds: 15);

  // Quickly switching apps back and forth should not stack identical alerts.
  // Every away period is still graded.
  static const Duration focusCooldown = Duration(seconds: 15);

  // Short, action-oriented, no numbers: each is under about 2 s spoken.
  String get phrase => switch (this) {
    VoiceAlert.followingDistance =>
      'Too close. Increase your following distance.',
    VoiceAlert.speeding => "Slow down, you're over the speed limit.",
    VoiceAlert.harshBraking => 'Brake more gently.',
    VoiceAlert.harshTurning => 'Take turns more slowly.',
    VoiceAlert.harshAccelerating => 'Accelerate more gently.',
    VoiceAlert.focus => 'Stay in the app while driving.',
  };

  // Lower is more urgent.
  int get priority => index;

  Duration get cooldown => switch (this) {
    VoiceAlert.followingDistance => followingDistanceCooldown,
    VoiceAlert.speeding => speedingCooldown,
    VoiceAlert.harshBraking ||
    VoiceAlert.harshTurning ||
    VoiceAlert.harshAccelerating => smoothnessCooldown,
    VoiceAlert.focus => focusCooldown,
  };
}

class VoiceAlertDetector {
  VoiceAlertDetector({
    required this.drivingMode,
    required this._speedGrading,
    required this._smoothnessGrading,
    FocusedDrivingGradingService? focusedDrivingGrading,
    FollowingDistanceMonitoringService? followingDistanceMonitoring,
  }) : _focusedDrivingGrading = drivingMode.tracksFocus
           ? focusedDrivingGrading
           : null,
       _followingDistanceMonitoring = drivingMode.tracksFollowingDistance
           ? followingDistanceMonitoring
           : null {
    // Start from the graders' current state so nothing that happened before
    // the detector existed is announced.
    _wasSpeeding = _speedGrading.isPenalizing;
    _wasFollowingTooClosely =
        _followingDistanceMonitoring?.isPenalizing ?? false;
    for (final category in SmoothnessCategory.values) {
      _smoothnessCounts[category] = _smoothnessGrading.violationCountFor(
        category,
      );
    }
    _focusCount = _focusedDrivingGrading?.violationCount ?? 0;
  }

  final DrivingMode drivingMode;
  final SpeedGradingService _speedGrading;
  final SmoothnessGradingService _smoothnessGrading;
  final FocusedDrivingGradingService? _focusedDrivingGrading;
  final FollowingDistanceMonitoringService? _followingDistanceMonitoring;

  bool _wasSpeeding = false;
  bool _wasFollowingTooClosely = false;
  final Map<SmoothnessCategory, int> _smoothnessCounts = {};
  int _focusCount = 0;

  static const Map<SmoothnessCategory, VoiceAlert> _smoothnessAlerts = {
    SmoothnessCategory.braking: VoiceAlert.harshBraking,
    SmoothnessCategory.accelerating: VoiceAlert.harshAccelerating,
    SmoothnessCategory.turning: VoiceAlert.harshTurning,
  };

  // Alerts whose onset happened since the previous call, in priority order.
  // Call this after feeding the graders; it is cheap enough for sensor rate.
  List<VoiceAlert> detectNewAlerts() {
    final alerts = <VoiceAlert>[];

    final following = _followingDistanceMonitoring;
    if (following != null) {
      final isFollowingTooClosely = following.isPenalizing;
      if (isFollowingTooClosely && !_wasFollowingTooClosely) {
        alerts.add(VoiceAlert.followingDistance);
      }
      _wasFollowingTooClosely = isFollowingTooClosely;
    }

    final isSpeeding = _speedGrading.isPenalizing;
    if (isSpeeding && !_wasSpeeding) alerts.add(VoiceAlert.speeding);
    _wasSpeeding = isSpeeding;

    for (final MapEntry(key: category, value: alert)
        in _smoothnessAlerts.entries) {
      final count = _smoothnessGrading.violationCountFor(category);
      if (count > _smoothnessCounts[category]!) alerts.add(alert);
      _smoothnessCounts[category] = count;
    }

    final focus = _focusedDrivingGrading;
    if (focus != null) {
      final count = focus.violationCount;
      if (count > _focusCount) alerts.add(VoiceAlert.focus);
      _focusCount = count;
    }

    alerts.sort((a, b) => a.priority.compareTo(b.priority));
    return alerts;
  }
}
