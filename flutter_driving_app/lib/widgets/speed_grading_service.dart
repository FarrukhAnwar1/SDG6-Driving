// Computes the Proper Speed driving grade (0-100, starting at 100)
// and provides a violations list.
//
// GRADING RULE:
// Driving >= the server's speedingThresholdMph over the limit only starts
// costing points once it has been sustained for >= [graceDuration]
// continuously. Once that grace window has been exceeded, every additional
// second costs 1 point at the threshold, plus 1 more point per 5 mph beyond
// it (scaled continuously). Dropping under the threshold or losing the limit
// ends the graded streak and resets grace. Nearby streaks on the same named
// road are grouped into one violation without charging for the gaps.
//
// RECOVERY:
// Whenever the driver is not currently speeding at all, the grade slowly
// regenerates back toward 100 at [regenPointsPerMinute] points per minute
// of clean driving (capped at 100). Sitting inside the grace window (over
// the limit, but not yet sustained for 5s) is treated as neutral.

// One or more nearby speeding streaks on the same road. Each must clear the
// grace window; brief excursions never become violations.
class SpeedingViolation {
  const SpeedingViolation({
    required this.startTime,
    required this.endTime,
    required this.latitude,
    required this.longitude,
    required this.speedLimitMph,
    required this.peakSpeedMph,
    required this.penalizedDuration,
    this.roadName,
  });

  // startTime is when the streak first went over the threshold, so it
  // includes the grace window that was never charged against the grade.
  final DateTime startTime;
  final DateTime endTime;

  // Where the violation started
  final double latitude;
  final double longitude;
  final String? roadName;

  // Posted or inferred limit when the streak began
  final double speedLimitMph;

  // Fastest speed reached during the streak
  final double peakSpeedMph;

  Duration get duration => endTime.difference(startTime);

  // Actual graded time, excluding every streak's grace window and any gaps
  // between grouped streaks. The start/end span alone cannot give this value.
  final Duration penalizedDuration;

  double get peakOverLimitMph => peakSpeedMph - speedLimitMph;
}

class SpeedGradingService {
  // Penalize if speeding for at least this long
  static const Duration graceDuration = Duration(seconds: 5);
  // Base rate at the threshold; each additional 5 mph adds another base rate.
  static const double pointsPerSecondOverThreshold = 1;
  static const double mphPerPenaltyStep = 5;

  // Long enough to bridge a timed-out lookup and the next 4-second refresh.
  static const Duration violationMergeWindow = Duration(seconds: 10);

  // Turned off point regen for now
  static const double regenPointsPerMinute = 0;

  double _grade = 100;
  DateTime? _violationStartTime;
  DateTime? _lastPenalizedThrough;
  DateTime? _lastSampleTime;

  // Timestamp of the most recent sample where the driver was speeding,
  // i.e. the end of the current streak if it were to stop right now.
  DateTime? _lastSpeedingTimestamp;

  // Graded streaks are recorded when they end. Nearby streaks on the same
  // named road update the previous entry (see _endCurrentStreak).
  final List<SpeedingViolation> _violations = [];
  int? _mergeCandidateIndex;

  // Details of the streak currently in progress, captured when it started so
  // the violation can record where it began and how far over the limit it got.
  double? _streakLatitude;
  double? _streakLongitude;
  String? _streakRoadName;
  double _streakSpeedLimitMph = 0;
  double _streakPeakSpeedMph = 0;

  double get grade => _grade;
  int get violationCount => _violations.length;

  // Closed violations, with grouped start/end times, the initial limit,
  // peak speed, and the coordinates where the first streak began.
  List<SpeedingViolation> get violations => List.unmodifiable(_violations);

  // Time spent over the threshold that was actually charged against the grade,
  // i.e. excluding gaps and each streak's grace window.
  Duration get totalSpeedingDuration => _violations.fold(
    Duration.zero,
    (total, violation) => total + violation.penalizedDuration,
  );

  // Called once per position update with the current speed, limit and the
  // server's tolerance for that road. Unknown limits/tolerances are ungraded.
  // latitude/longitude are the coordinates of that same
  // position update, used to tag where a violation started.
  void addSample({
    required double speedMph,
    required double? speedLimitMph,
    required double? speedingThresholdMph,
    required DateTime timestamp,
    required double latitude,
    required double longitude,
    String? roadName,
  }) {
    // Duplicate or out-of-order GPS fixes must not charge time twice or move
    // a violation's end backwards.
    if (_lastSampleTime != null && !timestamp.isAfter(_lastSampleTime!)) {
      return;
    }

    final elapsedSeconds = _lastSampleTime == null
        ? 0.0
        : timestamp.difference(_lastSampleTime!).inMilliseconds / 1000.0;

    final roadKey = _roadKey(roadName);
    // Missing lookup data is a gap; an identified different road is a boundary,
    // even when that road has no usable limit or the driver is not speeding.
    if (roadKey != null || speedLimitMph != null) {
      if (_violationStartTime != null && roadKey != _roadKey(_streakRoadName)) {
        _endCurrentStreak();
      }
      final candidateIndex = _mergeCandidateIndex;
      if (candidateIndex != null &&
          (roadKey == null ||
              roadKey != _roadKey(_violations[candidateIndex].roadName))) {
        _mergeCandidateIndex = null;
      }
    }

    if (!speedMph.isFinite ||
        speedMph < 0 ||
        speedLimitMph == null ||
        !speedLimitMph.isFinite ||
        speedLimitMph < 0 ||
        speedingThresholdMph == null ||
        !speedingThresholdMph.isFinite ||
        speedingThresholdMph < 0) {
      _endCurrentStreak();
      _lastSampleTime = timestamp;
      return;
    }

    final isSpeeding = (speedMph - speedLimitMph) >= speedingThresholdMph;

    if (!isSpeeding) {
      _regenerate(elapsedSeconds);
      _endCurrentStreak();
      _lastSampleTime = timestamp;
      return;
    }

    if (_violationStartTime == null) {
      _violationStartTime = timestamp;
      _streakLatitude = latitude;
      _streakLongitude = longitude;
      _streakRoadName = roadName?.trim();
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
      final excessMph = speedMph - speedLimitMph - speedingThresholdMph;
      final penaltyMultiplier = 1 + excessMph / mphPerPenaltyStep;
      final newGrade =
          _grade -
          penalizableSeconds * pointsPerSecondOverThreshold * penaltyMultiplier;
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
        endTime.difference(startTime) > graceDuration) {
      final penalizedDuration = endTime.difference(startTime) - graceDuration;
      final candidateIndex = _mergeCandidateIndex;
      final previous = candidateIndex == null
          ? null
          : _violations[candidateIndex];
      final gap = previous == null
          ? null
          : startTime.difference(previous.endTime);
      if (previous != null &&
          _roadKey(_streakRoadName) != null &&
          _roadKey(_streakRoadName) == _roadKey(previous.roadName) &&
          gap! >= Duration.zero &&
          gap <= violationMergeWindow) {
        _violations[candidateIndex!] = SpeedingViolation(
          startTime: previous.startTime,
          endTime: endTime,
          latitude: previous.latitude,
          longitude: previous.longitude,
          roadName: previous.roadName,
          speedLimitMph: previous.speedLimitMph,
          peakSpeedMph: _streakPeakSpeedMph > previous.peakSpeedMph
              ? _streakPeakSpeedMph
              : previous.peakSpeedMph,
          penalizedDuration: previous.penalizedDuration + penalizedDuration,
        );
      } else {
        _violations.add(
          SpeedingViolation(
            startTime: startTime,
            endTime: endTime,
            latitude: latitude,
            longitude: longitude,
            roadName: _streakRoadName,
            speedLimitMph: _streakSpeedLimitMph,
            peakSpeedMph: _streakPeakSpeedMph,
            penalizedDuration: penalizedDuration,
          ),
        );
        _mergeCandidateIndex = _roadKey(_streakRoadName) == null
            ? null
            : _violations.length - 1;
      }
    }

    _violationStartTime = null;
    _lastPenalizedThrough = null;
    _lastSpeedingTimestamp = null;
    _streakLatitude = null;
    _streakLongitude = null;
    _streakRoadName = null;
  }

  static String? _roadKey(String? name) {
    final key = name?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return key == null || key.isEmpty ? null : key;
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
    _mergeCandidateIndex = null;
    _streakLatitude = null;
    _streakLongitude = null;
    _streakRoadName = null;
    _streakSpeedLimitMph = 0;
    _streakPeakSpeedMph = 0;
  }
}
