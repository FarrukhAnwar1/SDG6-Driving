// Combines camera measurements with fresh GPS fixes to grade following distance.

import '../driving/driving_mode.dart';
import 'following_distance_grading_service.dart';
import 'vehicle_distance_estimator.dart';

// Joins camera observations to fresh, trusted GPS fixes. Camera callbacks alone
// cannot keep grading a stale speed/location after GPS stops delivering data.
class FollowingDistanceMonitoringService {
  FollowingDistanceMonitoringService({
    required this.drivingMode,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const Duration maxPositionAge = Duration(seconds: 2);
  static const Duration maxMeasurementAge = Duration(seconds: 1);
  final DrivingMode drivingMode;
  final DateTime Function() _clock;
  final FollowingDistanceGradingService _grading =
      FollowingDistanceGradingService();

  bool _active = false;
  bool _finalized = false;
  ({double speedMph, double latitude, double longitude, DateTime timestamp})?
  _position;
  DateTime? _lastMeasurementTime;
  FollowingDistanceStatus _status = FollowingDistanceStatus.waiting;
  double? _headwaySeconds;

  bool get isActive => _active && !_finalized;
  double? get grade =>
      drivingMode.tracksFollowingDistance ? _grading.grade : null;
  List<FollowingDistanceViolation> get violations =>
      drivingMode.tracksFollowingDistance ? _grading.violations : const [];
  FollowingDistanceStatus get status => _status;
  double? get headwaySeconds => _headwaySeconds;

  void resume() {
    if (_finalized || !drivingMode.tracksFollowingDistance) return;
    _active = true;
    _position = null;
    _status = FollowingDistanceStatus.waiting;
  }

  void pause() {
    _active = false;
    _position = null;
    _interrupt(FollowingDistanceStatus.paused);
  }

  void updatePosition({
    required double speedMph,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
  }) {
    if (!isActive) return;
    if (!speedMph.isFinite ||
        speedMph < 0 ||
        !latitude.isFinite ||
        latitude.abs() > 90 ||
        !longitude.isFinite ||
        longitude.abs() > 180 ||
        !_isFresh(timestamp, _clock(), maxPositionAge)) {
      invalidatePosition();
      return;
    }
    if (_position != null && !timestamp.isAfter(_position!.timestamp)) return;
    _position = (
      speedMph: speedMph,
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
    );
    if (speedMph < FollowingDistanceGradingService.minimumSpeedMph) {
      _interrupt(FollowingDistanceStatus.waiting);
    }
  }

  void invalidatePosition() {
    _position = null;
    _interrupt(FollowingDistanceStatus.unavailable);
  }

  void addMeasurement(FollowingDistanceMeasurement measurement) {
    if (!isActive) return;
    final timestamp = measurement.timestamp;
    if (_lastMeasurementTime != null &&
        !timestamp.isAfter(_lastMeasurementTime!)) {
      return;
    }
    final now = _clock();
    final position = _position;
    if (!_isFresh(timestamp, now, maxMeasurementAge) ||
        position == null ||
        !_isFresh(position.timestamp, now, maxPositionAge) ||
        timestamp.difference(position.timestamp).abs() > maxPositionAge) {
      _interrupt(FollowingDistanceStatus.unavailable);
      return;
    }
    _lastMeasurementTime = timestamp;
    if (measurement.status != FollowingDistanceStatus.tracking ||
        measurement.distanceMeters == null ||
        !measurement.distanceMeters!.isFinite ||
        measurement.distanceMeters! <= 0) {
      _interrupt(
        measurement.status == FollowingDistanceStatus.tracking
            ? FollowingDistanceStatus.unreliable
            : measurement.status,
      );
      return;
    }
    if (position.speedMph < FollowingDistanceGradingService.minimumSpeedMph) {
      _interrupt(FollowingDistanceStatus.waiting);
      return;
    }
    _status = FollowingDistanceStatus.tracking;
    _headwaySeconds =
        measurement.distanceMeters! /
        (position.speedMph *
            FollowingDistanceGradingService.metersPerSecondPerMph);
    _grading.addSample(
      speedMph: position.speedMph,
      distanceMeters: measurement.distanceMeters,
      timestamp: timestamp,
      latitude: position.latitude,
      longitude: position.longitude,
      leadVehicleId: measurement.leadVehicleId,
    );
  }

  void cameraUnavailable() {
    if (isActive) _interrupt(FollowingDistanceStatus.unavailable);
  }

  void checkForInterruption() {
    if (!isActive) return;
    final now = _clock();
    if ((_lastMeasurementTime != null &&
            !_isFresh(_lastMeasurementTime!, now, maxMeasurementAge)) ||
        (_position != null &&
            !_isFresh(_position!.timestamp, now, maxPositionAge))) {
      _interrupt(FollowingDistanceStatus.unavailable);
    }
  }

  void _interrupt(FollowingDistanceStatus status) {
    _grading.interrupt();
    _headwaySeconds = null;
    _status = status;
  }

  // Reject future timestamps as well as expired observations. A small clock
  // allowance covers native and Dart timestamp rounding at frame delivery.
  bool _isFresh(DateTime timestamp, DateTime now, Duration maximumAge) {
    final age = now.difference(timestamp);
    return age >= const Duration(milliseconds: -100) && age <= maximumAge;
  }

  void finalizeTrip() {
    _grading.finalizeTrip();
    _active = false;
    _finalized = true;
    _position = null;
  }
}
