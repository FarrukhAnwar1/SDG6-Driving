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
  // A frame retains its capture/delivery timestamp through native inference.
  static const Duration maxMeasurementAge =
      FollowingDistanceGradingService.maxProcessingDuration;
  static const Duration positionHistoryAge = Duration(seconds: 8);
  final DrivingMode drivingMode;
  final DateTime Function() _clock;
  final FollowingDistanceGradingService _grading =
      FollowingDistanceGradingService();

  bool _active = false;
  bool _finalized = false;
  ({double speedMph, double latitude, double longitude, DateTime timestamp})?
  _position;
  final _positions =
      <
        ({
          double speedMph,
          double latitude,
          double longitude,
          DateTime timestamp,
        })
      >[];
  DateTime? _lastMeasurementTime;
  DateTime? _lastMeasurementReceivedAt;
  DateTime? _processingTimestamp;
  DateTime? _acceptFrom;
  FollowingDistanceStatus _status = FollowingDistanceStatus.waiting;
  double? _headwaySeconds;

  bool get isActive => _active && !_finalized;
  double? get grade =>
      drivingMode.tracksFollowingDistance ? _grading.grade : null;
  List<FollowingDistanceViolation> get violations =>
      drivingMode.tracksFollowingDistance ? _grading.violations : const [];
  FollowingDistanceStatus get status => _status;
  double? get headwaySeconds => _headwaySeconds;
  Duration? get measurementAge => _lastMeasurementTime == null
      ? null
      : _clock().difference(_lastMeasurementTime!);

  void resume() {
    if (_finalized || !drivingMode.tracksFollowingDistance) return;
    _active = true;
    _position = null;
    _positions.clear();
    _lastMeasurementTime = null;
    _lastMeasurementReceivedAt = null;
    _processingTimestamp = null;
    _acceptFrom = _clock();
    _status = FollowingDistanceStatus.waiting;
  }

  void pause() {
    _active = false;
    _position = null;
    _positions.clear();
    _processingTimestamp = null;
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
    _positions.add(_position!);
    _positions.removeWhere(
      (position) =>
          timestamp.difference(position.timestamp) > positionHistoryAge,
    );
    if (speedMph < FollowingDistanceGradingService.minimumSpeedMph) {
      _acceptFrom = timestamp;
      _interrupt(FollowingDistanceStatus.waiting);
    }
  }

  void invalidatePosition() {
    _position = null;
    _positions.clear();
    _lastMeasurementReceivedAt = null;
    _processingTimestamp = null;
    _acceptFrom = _clock();
    _interrupt(FollowingDistanceStatus.unavailable);
  }

  void beginMeasurement(DateTime timestamp) {
    if (!isActive ||
        !_isFresh(timestamp, _clock(), maxMeasurementAge) ||
        (_acceptFrom != null && timestamp.isBefore(_acceptFrom!))) {
      return;
    }
    _processingTimestamp = timestamp;
    // Keep a recent "no vehicle" or "confirming" result visible while the
    // next job runs, rather than flickering back to processing every frame.
    if ((_lastMeasurementTime == null ||
            _status == FollowingDistanceStatus.unavailable) &&
        _position != null &&
        _position!.speedMph >=
            FollowingDistanceGradingService.minimumSpeedMph) {
      _status = FollowingDistanceStatus.processing;
    }
  }

  void addMeasurement(FollowingDistanceMeasurement measurement) {
    if (!isActive) return;
    final timestamp = measurement.timestamp;
    final processingDuration = _processingTimestamp == timestamp
        ? _clock().difference(timestamp)
        : Duration.zero;
    if (_processingTimestamp == timestamp) _processingTimestamp = null;
    // Late model results cannot revive a streak from before a GPS/camera fault
    // or a lifecycle restart.
    if (_acceptFrom != null && timestamp.isBefore(_acceptFrom!)) return;
    if (_lastMeasurementTime != null &&
        !timestamp.isAfter(_lastMeasurementTime!)) {
      return;
    }
    final now = _clock();
    final latestPosition = _position;
    final eligible = _positions.where(
      (position) =>
          !position.timestamp.isAfter(
            timestamp.add(const Duration(milliseconds: 100)),
          ) &&
          timestamp.difference(position.timestamp) <= maxPositionAge,
    );
    final position = eligible.isEmpty ? null : eligible.last;
    if (!_isFresh(timestamp, now, maxMeasurementAge) ||
        position == null ||
        latestPosition == null ||
        !_isFresh(latestPosition.timestamp, now, maxPositionAge) ||
        timestamp.difference(position.timestamp).abs() > maxPositionAge) {
      _interrupt(FollowingDistanceStatus.unavailable);
      return;
    }
    _lastMeasurementTime = timestamp;
    _lastMeasurementReceivedAt = now;
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
      processingDuration: processingDuration,
    );
  }

  void cameraUnavailable() {
    if (isActive) {
      _acceptFrom = _clock();
      // One outage establishes one cutoff. Retaining the expired delivery time
      // would make every watchdog tick advance the cutoff again, permanently
      // rejecting even fresh frames that arrive with normal inference latency.
      _lastMeasurementReceivedAt = null;
      _processingTimestamp = null;
      _interrupt(FollowingDistanceStatus.unavailable);
    }
  }

  void checkForInterruption() {
    if (!isActive) return;
    final now = _clock();
    // Silence is measured from delivery, while grading always uses capture
    // timestamps. Valid inference latency must not trigger a false outage.
    if (_position != null &&
        !_isFresh(_position!.timestamp, now, maxPositionAge)) {
      invalidatePosition();
    } else if (_processingTimestamp != null) {
      if (!_isFresh(_processingTimestamp!, now, maxMeasurementAge)) {
        cameraUnavailable();
      } else if (measurementAge != null &&
          measurementAge! > maxMeasurementAge) {
        _headwaySeconds = null;
        _status = FollowingDistanceStatus.processing;
      }
    } else if (_lastMeasurementReceivedAt != null &&
        !_isFresh(
          _lastMeasurementReceivedAt!,
          now,
          FollowingDistanceGradingService.maxSampleGap,
        )) {
      cameraUnavailable();
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
    _positions.clear();
    _processingTimestamp = null;
  }
}
