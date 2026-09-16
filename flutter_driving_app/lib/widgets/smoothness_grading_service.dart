// Computes the Smooth Braking / Smooth Accelerating / Smooth Turning grades
// (0-100, starting at 100) using accelerometer samples and provides violations lists.

// GRADING RULE:
// A g-force event must stay at or above [violationThresholdG] continuously for
// at least [violationConfirmationDuration] before it becomes a violation.
// This confirmation window rejects short impulses such as potholes, road seams,
// and quick mount shakes that can create a large instantaneous sensor spike but
// do not represent sustained harsh driving.
//
// Once confirmed, the violation is timed from when the sustained spike actually
// began (not from the end of the confirmation window). A flat
// [basePenaltyPerViolation] is charged for the event, plus a per-g-over-threshold
// [penaltyPerGOverThreshold] and per-second-of-duration [penaltyPerSecond], so a
// harder or longer event costs more.

// COOLDOWN RULE:
// If a new spike in the same category starts within [violationCooldown] of
// the previous one ending, it's merged into that same violation (extending
// its end time and taking the higher of the two peaks) instead of being
// counted as a second violation. For example, this can keep a few short
// taps on the brakes during one panic stop, from being counted and penalized
// as several separate events.
import 'dart:math' as math;

enum SmoothnessCategory { braking, accelerating, turning }

extension SmoothnessCategoryLabel on SmoothnessCategory {
  String get label {
    switch (this) {
      case SmoothnessCategory.braking:
        return 'Smooth Braking';
      case SmoothnessCategory.accelerating:
        return 'Smooth Accelerating';
      case SmoothnessCategory.turning:
        return 'Smooth Turning';
    }
  }
}

// One continuous stretch of time where a category's g-force stayed at or
// above g-force threshold
class SmoothnessViolation {
  SmoothnessViolation({
    required this.category,
    required this.startTime,
    required this.endTime,
    required this.latitude,
    required this.longitude,
    required this.peakGForce,
  });

  final SmoothnessCategory category;
  final DateTime startTime;
  final DateTime endTime;

  // Where the violation started
  final double latitude;
  final double longitude;

  final double peakGForce;

  Duration get duration => endTime.difference(startTime);
}

class _OpenViolation {
  _OpenViolation({
    required this.startTime,
    required this.latitude,
    required this.longitude,
    required this.peakGForce,
  });

  final DateTime startTime;
  final double latitude;
  final double longitude;
  double peakGForce;
}

// A threshold crossing that has not lasted long enough to count yet.
// Keeping this separate from _OpenViolation is what prevents one-sample
// potholes / mount jolts from immediately affecting the grade.
class _ViolationCandidate {
  _ViolationCandidate({
    required this.startTime,
    required this.latitude,
    required this.longitude,
    required this.peakGForce,
  });

  final DateTime startTime;
  final double latitude;
  final double longitude;
  double peakGForce;
}

class SmoothnessGradingService {
  // A sustained g-force at or above this level can count as a violation.
  static const double violationThresholdG = 0.5;

  // The signal must remain above violationThresholdG for at least this long
  // before it is promoted from a candidate to a real violation.
  //
  // 350 ms is intentionally long enough to reject most pothole / road-seam /
  // mount-jolt impulses, while still being short relative to genuine harsh
  // braking, acceleration, or cornering events, which normally persist for
  // substantially longer than a few tenths of a second.
  static const Duration violationConfirmationDuration = Duration(
    milliseconds: 350,
  );

  // See COOLDOWN RULE above
  static const Duration violationCooldown = Duration(seconds: 5);

  static const double _startingGrade = 100;

  // Flat cost for a violation happening at all, plus a per-g-over-threshold
  // and per-second-of-duration cost, so a harder or longer event costs more.
  static const double _basePenaltyPerViolation = 4;
  static const double _penaltyPerGOverThreshold = 20;
  static const double _penaltyPerSecond = 3;

  // Exponential moving average applied to raw accelerometer samples before
  // threshold-checking, to cut sensor noise without meaningfully delaying
  // real events, similar to _speedSmoothingAlpha in LiveDashboardScreen.
  static const double _smoothingAlpha = 0.6;

  final Map<SmoothnessCategory, List<SmoothnessViolation>> _violations = {
    for (final category in SmoothnessCategory.values) category: [],
  };

  final Map<SmoothnessCategory, _OpenViolation?> _openViolations = {
    for (final category in SmoothnessCategory.values) category: null,
  };

  // Threshold crossings that have not yet survived the confirmation window.
  // These never affect grades, counts, or violation lists unless promoted.
  final Map<SmoothnessCategory, _ViolationCandidate?> _candidates = {
    for (final category in SmoothnessCategory.values) category: null,
  };

  // The most recently closed violation per category, kept around just long
  // enough to check whether the next spike falls inside its cooldown window.
  final Map<SmoothnessCategory, SmoothnessViolation?> _lastClosedViolation = {
    for (final category in SmoothnessCategory.values) category: null,
  };

  final Map<SmoothnessCategory, double> _smoothedG = {
    for (final category in SmoothnessCategory.values) category: 0,
  };

  DateTime? _lastSampleTime;

  // Feed one accelerometer reading in, already resolved into a signed
  // g-force for the forward/backward axis and the left/right axis.
  // forwardG should be positive while accelerating forward and negative
  // while braking/decelerating. lateralG is the signed left/right
  // g-force. Only its magnitude is graded here since a hard turn is a hard
  // turn in either direction. latitude/longitude should be the most
  // recent known GPS update, used to tag where any violation happened.
  void addSample({
    required double forwardG,
    required double lateralG,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
  }) {
    _lastSampleTime = timestamp;

    _evaluate(
      category: SmoothnessCategory.accelerating,
      rawG: forwardG > 0 ? forwardG : 0,
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
    );
    _evaluate(
      category: SmoothnessCategory.braking,
      rawG: forwardG < 0 ? -forwardG : 0,
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
    );
    _evaluate(
      category: SmoothnessCategory.turning,
      rawG: lateralG.abs(),
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
    );
  }

  void _evaluate({
    required SmoothnessCategory category,
    required double rawG,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
  }) {
    final smoothed =
        (_smoothingAlpha * rawG) +
        ((1 - _smoothingAlpha) * _smoothedG[category]!);
    _smoothedG[category] = smoothed;

    final open = _openViolations[category];

    if (smoothed >= violationThresholdG) {
      // Once an event is confirmed, keep tracking it exactly as before.
      if (open != null) {
        open.peakGForce = math.max(open.peakGForce, smoothed);
        return;
      }

      final candidate = _candidates[category];
      if (candidate == null) {
        // First sample above threshold: remember it, but do not penalize yet.
        _candidates[category] = _ViolationCandidate(
          startTime: timestamp,
          latitude: latitude,
          longitude: longitude,
          peakGForce: smoothed,
        );
        return;
      }

      candidate.peakGForce = math.max(candidate.peakGForce, smoothed);

      final candidateAge = timestamp.difference(candidate.startTime);
      if (candidateAge.isNegative) {
        // Out-of-order timestamps should not be able to confirm an event.
        _candidates[category] = _ViolationCandidate(
          startTime: timestamp,
          latitude: latitude,
          longitude: longitude,
          peakGForce: smoothed,
        );
        return;
      }

      if (candidateAge >= violationConfirmationDuration) {
        _promoteCandidate(category, candidate);
        _candidates[category] = null;
      }
      return;
    }

    // Falling below threshold before confirmation means it was only a short
    // impulse. Discard it completely: no grade penalty and no event count.
    _candidates[category] = null;

    if (open != null) {
      _closeViolation(category, open, timestamp);
      _openViolations[category] = null;
    }
  }

  void _promoteCandidate(
    SmoothnessCategory category,
    _ViolationCandidate candidate,
  ) {
    final lastClosed = _lastClosedViolation[category];
    final withinCooldown =
        lastClosed != null &&
        candidate.startTime.difference(lastClosed.endTime) <=
            violationCooldown &&
        !candidate.startTime.isBefore(lastClosed.endTime);

    if (withinCooldown) {
      // The new sustained event is close enough to the previous confirmed
      // violation to be the same driving maneuver. Reopen the old one only
      // AFTER this new spike has itself survived the confirmation window.
      _violations[category]!.removeLast();
      _openViolations[category] = _OpenViolation(
        startTime: lastClosed.startTime,
        latitude: lastClosed.latitude,
        longitude: lastClosed.longitude,
        peakGForce: math.max(lastClosed.peakGForce, candidate.peakGForce),
      );
      return;
    }

    _openViolations[category] = _OpenViolation(
      startTime: candidate.startTime,
      latitude: candidate.latitude,
      longitude: candidate.longitude,
      peakGForce: candidate.peakGForce,
    );
  }

  void _closeViolation(
    SmoothnessCategory category,
    _OpenViolation open,
    DateTime endTime,
  ) {
    final violation = SmoothnessViolation(
      category: category,
      startTime: open.startTime,
      endTime: endTime,
      latitude: open.latitude,
      longitude: open.longitude,
      peakGForce: open.peakGForce,
    );
    _violations[category]!.add(violation);
    _lastClosedViolation[category] = violation;
  }

  // Called when the trip ends to close out any CONFIRMED violation still in
  // progress. An unconfirmed candidate is intentionally discarded: if it did
  // not survive the confirmation window, it should not count just because the
  // driver happened to press Stop Trip during a pothole / brief jolt.
  void finalizeTrip() {
    final now = _lastSampleTime ?? DateTime.now();
    for (final category in SmoothnessCategory.values) {
      _candidates[category] = null;
      final open = _openViolations[category];
      if (open != null) {
        _closeViolation(category, open, now);
        _openViolations[category] = null;
      }
    }
  }

  // Live 0-100 grade for category. A threshold crossing does not affect the
  // grade during its confirmation window. Once confirmed, the event is scored
  // from its true original start time and remains live until it ends.
  double gradeFor(SmoothnessCategory category) {
    double penalty = 0;
    for (final violation in _violations[category]!) {
      penalty += _penaltyFor(violation);
    }

    final open = _openViolations[category];
    if (open != null && _lastSampleTime != null) {
      penalty += _penaltyFor(
        SmoothnessViolation(
          category: category,
          startTime: open.startTime,
          endTime: _lastSampleTime!,
          latitude: open.latitude,
          longitude: open.longitude,
          peakGForce: open.peakGForce,
        ),
      );
    }

    return math.max(0, _startingGrade - penalty);
  }

  double _penaltyFor(SmoothnessViolation violation) {
    final overThreshold = math.max(
      0.0,
      violation.peakGForce - violationThresholdG,
    );
    return _basePenaltyPerViolation +
        (overThreshold * _penaltyPerGOverThreshold) +
        (violation.duration.inMilliseconds / 1000.0 * _penaltyPerSecond);
  }

  // Number of violations recorded for category so far, including one
  // currently in progress if there is one.
  int violationCountFor(SmoothnessCategory category) =>
      _violations[category]!.length +
      (_openViolations[category] != null ? 1 : 0);

  // Closed violations for category, each with its start/end time and the
  // coordinates where it began.
  List<SmoothnessViolation> violationsFor(SmoothnessCategory category) =>
      List.unmodifiable(_violations[category]!);

  Duration totalDurationFor(SmoothnessCategory category) {
    var total = Duration.zero;
    for (final violation in _violations[category]!) {
      total += violation.duration;
    }
    final open = _openViolations[category];
    if (open != null && _lastSampleTime != null) {
      total += _lastSampleTime!.difference(open.startTime);
    }
    return total;
  }

  double get brakingGrade => gradeFor(SmoothnessCategory.braking);
  double get acceleratingGrade => gradeFor(SmoothnessCategory.accelerating);
  double get turningGrade => gradeFor(SmoothnessCategory.turning);
}
