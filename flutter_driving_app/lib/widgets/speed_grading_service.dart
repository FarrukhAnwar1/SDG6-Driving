// Computes the Proper Speed driving grade (0-100, starting at 100)
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

// TODO: Potentially introduce hysteresis band or a rolling-window average for
// more accurate grading
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

  // A "speeding offense" is one continuous streak that was sustained past
  // graceDuration (i.e. one that actually cost grade points). Streaks that
  // never clear the grace window are jitter/brief excursions, not offenses.
  // totalSpeedingDuration only counts time past the grace period (the part
  // that was actually penalized), not the grace period itself.
  int _offenseCount = 0;
  Duration _totalSpeedingDuration = Duration.zero;

  double get grade => _grade;
  int get speedingOffenseCount => _offenseCount;
  Duration get totalSpeedingDuration => _totalSpeedingDuration;

  // Called once per position update to feed the current speed and posted limit into the grading
  void addSample({
    required double speedMph,
    required double? speedLimitMph,
    required DateTime timestamp,
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

    _violationStartTime ??= timestamp;
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

  // Closes out the in-progress streak (if any), tallying it as an offense
  // when it was sustained past graceDuration, then clears streak state.
  // Tallied duration excludes the grace period itself, i.e. it's the same
  // span that was actually penalized against the grade.
  void _endCurrentStreak() {
    if (_violationStartTime != null && _lastSpeedingTimestamp != null) {
      final fullDuration = _lastSpeedingTimestamp!.difference(
        _violationStartTime!,
      );
      if (fullDuration >= graceDuration) {
        _offenseCount++;
        _totalSpeedingDuration += fullDuration - graceDuration;
      }
    }
    _violationStartTime = null;
    _lastSpeedingTimestamp = null;
  }

  // Call once when the trip ends, so a streak still in progress at that
  // moment (driver was speeding right up until Stop Trip was pressed) still
  // gets tallied instead of being silently dropped.
  void finalizeTrip() {
    _endCurrentStreak();
  }

  void reset() {
    _grade = 100;
    _violationStartTime = null;
    _lastPenalizedThrough = null;
    _lastSampleTime = null;
    _lastSpeedingTimestamp = null;
    _offenseCount = 0;
    _totalSpeedingDuration = Duration.zero;
  }
}
