// Computes the Adequate Following Distance grade (0-100, starting at 100)
// from observed vehicle distances and driving speeds, and records violations.
//
// GRADING RULE:
// Only grade at or above [minimumSpeedMph]. Headway in seconds is
// distanceMeters / (speedMph * [metersPerSecondPerMph]). A headway at or above
// [requiredHeadwaySeconds] is safe for this grading rule.
// A shorter gap must persist continuously for more than [graceDuration]
// before points are deducted. The grace period is never charged.
//
// After grace, each observed second costs [pointsPerSecond], scaled
// by 1 + (requiredHeadwaySeconds - headway) / [secondsPerPenaltyStep].
// Severity scales continuously; the grade is clamped to 0-100 with no recovery.
//
// INTERRUPTION RULE:
// A safe gap, speed below threshold, invalid/missing distance or invalid speed/GPS
// coordinates, a different lead vehicle, an unexplained observation gap,
// or an explicit monitoring interruption ends the streak at
// its last unsafe observation. A new streak gets a fresh grace period; separate
// streaks are never merged or charged for the interruption. Duplicate and
// out-of-order samples are ignored.
// At the nominal one FPS, [maxSampleGap] includes scheduling tolerance. A
// measured processing job may extend the NEXT observation's deadline by its
// actual duration (bounded by [maxProcessingDuration]) plus 500ms. The current
// job cannot excuse an earlier gap. Camera-stream and GPS outages always reset
// grace, even when a model is busy. All penalties use capture timestamps.
//
// VIOLATION RECORDS:
// Only streaks with a post-grace penalty are recorded. Start/end times include
// the observed grace period, while [penalizedDuration] counts only charged time.
// Records also retain starting coordinates/speed and minimum headway/distance.
// Finalizing the trip closes the last streak and freezes further grading.

import 'package:flutter/foundation.dart';

@immutable
class FollowingDistanceViolation {
  const FollowingDistanceViolation({
    required this.startTime,
    required this.endTime,
    required this.latitude,
    required this.longitude,
    required this.minimumHeadwaySeconds,
    required this.minimumDistanceMeters,
    required this.speedAtStartMph,
    required this.penalizedDuration,
  });

  final DateTime startTime;
  final DateTime endTime;
  final double latitude;
  final double longitude;
  final double minimumHeadwaySeconds;
  final double minimumDistanceMeters;
  final double speedAtStartMph;
  final Duration penalizedDuration;
  Duration get duration => endTime.difference(startTime);
}

class FollowingDistanceGradingService {
  static const double minimumSpeedMph = 25;
  static const double requiredHeadwaySeconds = 1.5;
  static const Duration graceDuration = Duration(seconds: 5);
  // Default one-FPS deadline. Only verified previous processing can extend it.
  static const Duration maxSampleGap = Duration(milliseconds: 1500);
  static const Duration maxProcessingDuration = Duration(seconds: 5);
  static const double pointsPerSecond = 1;
  static const double secondsPerPenaltyStep = 0.5;
  static const double metersPerSecondPerMph = 0.44704;

  double _grade = 100;
  DateTime? _lastSampleTime;
  Duration _nextSampleGap = maxSampleGap;
  _FollowingStreak? _streak;
  bool _finalized = false;
  final List<FollowingDistanceViolation> _violations = [];

  double get grade => _grade;
  List<FollowingDistanceViolation> get violations =>
      List.unmodifiable(_violations);

  void addSample({
    required double speedMph,
    required double? distanceMeters,
    required DateTime timestamp,
    required double latitude,
    required double longitude,
    String? leadVehicleId,
    Duration processingDuration = Duration.zero,
  }) {
    if (_finalized) return;
    final previous = _lastSampleTime;
    if (previous != null && !timestamp.isAfter(previous)) return;
    if (previous != null && timestamp.difference(previous) > _nextSampleGap) {
      interrupt();
    }
    _lastSampleTime = timestamp;
    // Only the previous job can explain the interval before this observation.
    // A slow current result must never excuse an earlier hole in monitoring.
    final measuredProcessing =
        processingDuration >= Duration.zero &&
            processingDuration <= maxProcessingDuration
        ? processingDuration
        : Duration.zero;
    _nextSampleGap = measuredProcessing > const Duration(seconds: 1)
        ? measuredProcessing + const Duration(milliseconds: 500)
        : maxSampleGap;

    if (!speedMph.isFinite ||
        speedMph < minimumSpeedMph ||
        distanceMeters == null ||
        !distanceMeters.isFinite ||
        distanceMeters <= 0 ||
        !latitude.isFinite ||
        latitude.abs() > 90 ||
        !longitude.isFinite ||
        longitude.abs() > 180) {
      interrupt();
      return;
    }

    final headway = distanceMeters / (speedMph * metersPerSecondPerMph);
    if (headway >= requiredHeadwaySeconds) {
      interrupt();
      return;
    }

    if (_streak != null && _streak!.leadVehicleId != leadVehicleId) {
      interrupt();
    }
    final streak = _streak ??= _FollowingStreak(
      startTime: timestamp,
      latitude: latitude,
      longitude: longitude,
      speedAtStartMph: speedMph,
      minimumHeadwaySeconds: headway,
      minimumDistanceMeters: distanceMeters,
      leadVehicleId: leadVehicleId,
    );
    streak.lastObserved = timestamp;
    if (headway < streak.minimumHeadwaySeconds) {
      streak.minimumHeadwaySeconds = headway;
    }
    if (distanceMeters < streak.minimumDistanceMeters) {
      streak.minimumDistanceMeters = distanceMeters;
    }

    final graceEnd = streak.startTime.add(graceDuration);
    final chargeFrom = streak.penalizedThrough ?? graceEnd;
    if (!timestamp.isAfter(chargeFrom)) return;
    final charged = timestamp.difference(chargeFrom);
    // Same sustained-event approach as speed grading: no recovery, a base
    // point/second plus severity, and a score clamped to [0, 100].
    final severity =
        1 + (requiredHeadwaySeconds - headway) / secondsPerPenaltyStep;
    _grade =
        (_grade - charged.inMicroseconds / 1e6 * pointsPerSecond * severity)
            .clamp(0.0, 100.0);
    streak.penalizedDuration += charged;
    streak.penalizedThrough = timestamp;
  }

  // Closing at the last observed unsafe frame excludes unknown and safe time.
  // Grace-only candidates never appear as violations, including at trip stop.
  void interrupt() {
    final streak = _streak;
    if (streak != null && streak.penalizedDuration > Duration.zero) {
      _violations.add(
        FollowingDistanceViolation(
          startTime: streak.startTime,
          endTime: streak.lastObserved,
          latitude: streak.latitude,
          longitude: streak.longitude,
          minimumHeadwaySeconds: streak.minimumHeadwaySeconds,
          minimumDistanceMeters: streak.minimumDistanceMeters,
          speedAtStartMph: streak.speedAtStartMph,
          penalizedDuration: streak.penalizedDuration,
        ),
      );
    }
    _streak = null;
  }

  void finalizeTrip() {
    interrupt();
    _finalized = true;
  }
}

class _FollowingStreak {
  _FollowingStreak({
    required this.startTime,
    required this.latitude,
    required this.longitude,
    required this.speedAtStartMph,
    required this.minimumHeadwaySeconds,
    required this.minimumDistanceMeters,
    required this.leadVehicleId,
  }) : lastObserved = startTime;

  final DateTime startTime;
  DateTime lastObserved;
  final double latitude;
  final double longitude;
  final double speedAtStartMph;
  final String? leadVehicleId;
  double minimumHeadwaySeconds;
  double minimumDistanceMeters;
  DateTime? penalizedThrough;
  Duration penalizedDuration = Duration.zero;
}
