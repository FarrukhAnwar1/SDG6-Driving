// Computes the Proper Speed driving grade (0-100, starting at 100)
// and provides a violations list.
//
// GRADING RULE:
// Driving >= [speedingThresholdMph] over the posted limit only starts
// costing points once it has been sustained for >= [graceDuration]
// continuously. Once that grace window has been exceeded, every additional
// second spent over the threshold costs [pointsPerSecondOverThreshold]
// points, until the driver drops back under the threshold (which resets
// the streak and grace window).
//
// RECOVERY:
// Whenever the driver is not currently speeding at all, the grade slowly
// regenerates back toward 100 at [regenPointsPerMinute] points per minute
// of clean driving (capped at 100). Sitting inside the grace window (over
// the limit, but not yet sustained for 5s) is treated as neutral.

// One continuous stretch of time where the driver stayed at least
// [SpeedGradingService.speedingThresholdMph] over the posted limit for at
// least [SpeedGradingService.graceDuration], i.e. a streak that actually cost
// grade points. Streaks that never clear the grace window are jitter/brief
// excursions and never become violations.
class SpeedingViolation {
  const SpeedingViolation({
    required this.startTime,
    required this.endTime,
    required this.latitude,
    required this.longitude,
    required this.speedLimitMph,
    required this.peakSpeedMph,
  });

  // startTime is when the streak first went over the threshold, so it
  // includes the grace window that was never charged against the grade.
  final DateTime startTime;
  final DateTime endTime;

  // Where the violation started
  final double latitude;
  final double longitude;

  // Posted limit when the streak began
  final double speedLimitMph;

  // Fastest speed reached during the streak
  final double peakSpeedMph;

  Duration get duration => endTime.difference(startTime);

  // The part of the streak past the grace window, which is the span that was
  // actually penalized against the grade.
  Duration get penalizedDuration =>
      duration - SpeedGradingService.graceDuration;

  double get peakOverLimitMph => peakSpeedMph - speedLimitMph;
}

class SpeedGradingService {
  // Penalize only if the driver is this many MPH over the posted limit
  static const double speedingThresholdMph = 5;
  // For at least this long
  static const Duration graceDuration = Duration(seconds: 5);
  // And by this many points per second
  static const double pointsPerSecondOverThreshold = 1;

  // Turned off point regen for now
  static const double regenPointsPerMinute = 0;

  double _grade = 100;
  DateTime? _violationStartTime;
  DateTime? _lastPenalizedThrough;
  DateTime? _lastSampleTime;

  // Timestamp of the most recent sample where the driver was speeding,
  // i.e. the end of the current streak if it were to stop right now.
  DateTime? _lastSpeedingTimestamp;

  // One entry per streak that was sustained past graceDuration, added when
  // the streak ends (see _endCurrentStreak).
  final List<SpeedingViolation> _violations = [];

  // Details of the streak currently in progress, captured when it started so
  // the violation can record where it began and how far over the limit it got.
  double? _streakLatitude;
  double? _streakLongitude;
  double _streakSpeedLimitMph = 0;
  double _streakPeakSpeedMph = 0;

  double get grade => _grade;
  int get violationCount => _violations.length;

  // Closed violations, each with its start/end time, the posted limit and peak
  // speed of the streak, and the coordinates where it began.
  List<SpeedingViolation> get violations => List.unmodifiable(_violations);

  // Time spent over the threshold that was actually charged against the grade,
  // i.e. excluding each violation's grace window.
  Duration get totalSpeedingDuration => _violations.fold(
    Duration.zero,
    (total, violation) => total + violation.penalizedDuration,
  );

  // Called once per position update to feed the current speed and posted limit
  // into the grading. latitude/longitude are the coordinates of that same
  // position update, used to tag where a violation started.
  void addSample({
    required double speedMph,
    required double? speedLimitMph,
    required DateTime timestamp,
    required double latitude,
    required double longitude,
  }) {
    final elapsedSeconds = _lastSampleTime == null
        ? 0.0
        : timestamp.difference(_lastSampleTime!).inMilliseconds / 1000.0;

    if (speedLimitMph == null) {
      _regenerate(elapsedSeconds);
      _endCurrentStreak();
      _lastPenalizedThrough = null;
      _lastSampleTime = timestamp;
      return;
    }

    final isSpeeding = (speedMph - speedLimitMph) >= speedingThresholdMph;

    if (!isSpeeding) {
      _regenerate(elapsedSeconds);
      _endCurrentStreak();
      _lastPenalizedThrough = null;
      _lastSampleTime = timestamp;
      return;
    }

    if (_violationStartTime == null) {
      _violationStartTime = timestamp;
      _streakLatitude = latitude;
      _streakLongitude = longitude;
      _streakSpeedLimitMph = speedLimitMph;
      _streakPeakSpeedMph = speedMph;
    } else if (speedMph > _streakPeakSpeedMph) {
      _streakPeakSpeedMph = speedMph;
    }

    _lastSpeedingTimestamp = timestamp;
    final elapsedInViolation = timestamp.difference(_violationStartTime!);

    if (elapsedInViolation < graceDuration) {
      _lastSampleTime = timestamp;
      return;
    }

    // Charge only for the portion of this streak that is both past the
    // grace window AND not already charged by an earlier sample
    final graceEnd = _violationStartTime!.add(graceDuration);
    final penalizeFrom =
        (_lastPenalizedThrough == null ||
            _lastPenalizedThrough!.isBefore(graceEnd))
        ? graceEnd
        : _lastPenalizedThrough!;

    final penalizableSeconds =
        timestamp.difference(penalizeFrom).inMilliseconds / 1000.0;

    if (penalizableSeconds > 0) {
      final newGrade =
          _grade - penalizableSeconds * pointsPerSecondOverThreshold;
      _grade = newGrade < 0 ? 0 : newGrade;
      _lastPenalizedThrough = timestamp;
    }

    _lastSampleTime = timestamp;
  }

  void _regenerate(double elapsedSeconds) {
    if (elapsedSeconds <= 0) return;
    final regained = elapsedSeconds / 60.0 * regenPointsPerMinute;
    final newGrade = _grade + regained;
    _grade = newGrade > 100 ? 100 : newGrade;
  }

  // Closes out the in-progress streak (if any), recording it as a violation
  // when it was sustained past graceDuration, then clears streak state.
  void _endCurrentStreak() {
    final startTime = _violationStartTime;
    final endTime = _lastSpeedingTimestamp;
    final latitude = _streakLatitude;
    final longitude = _streakLongitude;

    if (startTime != null &&
        endTime != null &&
        latitude != null &&
        longitude != null &&
        endTime.difference(startTime) >= graceDuration) {
      _violations.add(
        SpeedingViolation(
          startTime: startTime,
          endTime: endTime,
          latitude: latitude,
          longitude: longitude,
          speedLimitMph: _streakSpeedLimitMph,
          peakSpeedMph: _streakPeakSpeedMph,
        ),
      );
    }

    _violationStartTime = null;
    _lastSpeedingTimestamp = null;
    _streakLatitude = null;
    _streakLongitude = null;
  }

  // Call once when the trip ends, so a streak still in progress at that
  // moment (driver was speeding right up until Stop Trip was pressed) still
  // gets recorded instead of being silently dropped.
  void finalizeTrip() {
    _endCurrentStreak();
  }

  void reset() {
    _grade = 100;
    _violationStartTime = null;
    _lastPenalizedThrough = null;
    _lastSampleTime = null;
    _lastSpeedingTimestamp = null;
    _violations.clear();
    _streakLatitude = null;
    _streakLongitude = null;
    _streakSpeedLimitMph = 0;
    _streakPeakSpeedMph = 0;
  }
}
