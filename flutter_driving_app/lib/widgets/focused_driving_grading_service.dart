// Computes the Focused Driving grade (0-100, starting at 100) by using the
// WidgetsBindingObserver to detect leaving app and provides violations list.

// GRADING RULE:
// Flat [baseLeaveAppPenalty] points penalty for simply leaving the app while
// the vehicle is moving (>[minSpeedForViolationMph]) for more than [minViolationDuration]
// (to filter out quick events like notifications).
// There is also an additional per-second penalty [perSecondPenalty] for the duration of the distraction.
// The per-second penalty is scaled up for:
// - Higher speeds ([highSpeedPenaltyPerMphOverThreshold] for each mph
//                  over [highSpeedPenaltyThresholdMph])
// - Longer distractions ([extendedDistractionPenaltyPerSecond] for each second
//                        over [extendedDistractionThreshold])
// - Repeat offenses ([repeatOffenseMultiplierStep] for each additional violation,
//                    capped at [maxRepeatOffenseMultiplier])
import 'package:flutter/widgets.dart';

@immutable
class FocusedDrivingViolation {
  final DateTime startTime;
  final DateTime endTime;
  final Duration duration;
  final double speedAtStartMph;
  final double latitude;
  final double longitude;

  const FocusedDrivingViolation({
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.speedAtStartMph,
    required this.latitude,
    required this.longitude,
  });
}

class FocusedDrivingGradingService {
  static const double _minSpeedForViolationMph = 3.0;
  static const Duration _minViolationDuration = Duration(milliseconds: 1000);
  static const double _baseLeaveAppPenalty = 10.0;
  static const double _perSecondPenalty = 1.0;
  static const double _highSpeedPenaltyThresholdMph = 30.0;
  static const double _highSpeedPenaltyPerMphOverThreshold = 0.5;
  static const Duration _extendedDistractionThreshold = Duration(seconds: 5);
  static const double _extendedDistractionPenaltyPerSecond = 2.0;
  static const double _repeatOffenseMultiplierStep = 0.15;
  static const double _maxRepeatOffenseMultiplier = 2.0;

  static const double _minGrade = 0.0;
  static const double _maxGrade = 100.0;

  double _grade = _maxGrade;
  final List<FocusedDrivingViolation> _violations = [];

  bool _isAwayFromApp = false;
  DateTime? _awayStartTime;
  double _speedAtAwayStartMph = 0;
  double? _latitudeAtAwayStart;
  double? _longitudeAtAwayStart;

  double _lastKnownSpeedMph = 0;
  double? _lastKnownLatitude;
  double? _lastKnownLongitude;

  double get grade => _grade;
  int get violationCount => _violations.length;
  List<FocusedDrivingViolation> get violations =>
      List.unmodifiable(_violations);

  // Called on every live position update
  void updateLiveState({
    required double speedMph,
    required double latitude,
    required double longitude,
  }) {
    _lastKnownSpeedMph = speedMph;
    _lastKnownLatitude = latitude;
    _lastKnownLongitude = longitude;
  }

  // Called from the screen's WidgetsBindingObserver whenever the app's
  // lifecycle state changes. Only "resumed" counts as "in the app." Every
  // other state (inactive, paused, hidden, detached) means the driver's
  // attention has left the screen, so they're all treated as one "away"
  // state rather than trying to special-case each transition.
  void handleLifecycleStateChange(AppLifecycleState state, DateTime timestamp) {
    if (state == AppLifecycleState.resumed) {
      _handleAppForegrounded(timestamp);
    } else {
      _handleAppBackgrounded(timestamp);
    }
  }

  void _handleAppBackgrounded(DateTime timestamp) {
    // Already tracking an away period (i.e. inactive -> paused) so keep the
    // original start time/speed/location rather than resetting them.
    if (_isAwayFromApp) return;

    // Not moving (or no update yet) so not a distraction risk, so don't start
    // tracking. If the car starts moving before the app comes back to the
    // foreground, the next backgrounded transition will pick it up.
    if (_lastKnownSpeedMph < _minSpeedForViolationMph) return;
    final latitude = _lastKnownLatitude;
    final longitude = _lastKnownLongitude;
    if (latitude == null || longitude == null) return;

    _isAwayFromApp = true;
    _awayStartTime = timestamp;
    _speedAtAwayStartMph = _lastKnownSpeedMph;
    _latitudeAtAwayStart = latitude;
    _longitudeAtAwayStart = longitude;
  }

  void _handleAppForegrounded(DateTime timestamp) {
    if (!_isAwayFromApp) return;
    _isAwayFromApp = false;

    final startTime = _awayStartTime;
    final startLatitude = _latitudeAtAwayStart;
    final startLongitude = _longitudeAtAwayStart;
    final speedAtStart = _speedAtAwayStartMph;
    _awayStartTime = null;
    _latitudeAtAwayStart = null;
    _longitudeAtAwayStart = null;
    if (startTime == null || startLatitude == null || startLongitude == null) {
      return;
    }

    final duration = timestamp.difference(startTime);
    if (duration < _minViolationDuration) return;

    _violations.add(
      FocusedDrivingViolation(
        startTime: startTime,
        endTime: timestamp,
        duration: duration,
        speedAtStartMph: speedAtStart,
        latitude: startLatitude,
        longitude: startLongitude,
      ),
    );

    final penalty = _penaltyFor(
      duration: duration,
      speedAtStartMph: speedAtStart,
      violationIndexZeroBased: _violations.length - 1,
    );
    _grade = (_grade - penalty).clamp(_minGrade, _maxGrade);
  }

  double _penaltyFor({
    required Duration duration,
    required double speedAtStartMph,
    required int violationIndexZeroBased,
  }) {
    final seconds = duration.inMilliseconds / 1000.0;

    double penalty = _baseLeaveAppPenalty + (seconds * _perSecondPenalty);

    if (speedAtStartMph > _highSpeedPenaltyThresholdMph) {
      penalty +=
          (speedAtStartMph - _highSpeedPenaltyThresholdMph) *
          _highSpeedPenaltyPerMphOverThreshold;
    }

    final extendedSeconds = seconds - _extendedDistractionThreshold.inSeconds;
    if (extendedSeconds > 0) {
      penalty += extendedSeconds * _extendedDistractionPenaltyPerSecond;
    }

    final repeatOffenseMultiplier =
        (1.0 + (violationIndexZeroBased * _repeatOffenseMultiplierStep)).clamp(
          1.0,
          _maxRepeatOffenseMultiplier,
        );

    return penalty * repeatOffenseMultiplier;
  }

  // Closes out an away period still in progress when the trip ends so a
  // trailing violation isn't silently dropped.
  void finalizeTrip() {
    if (_isAwayFromApp) {
      _handleAppForegrounded(DateTime.now());
    }
  }
}
