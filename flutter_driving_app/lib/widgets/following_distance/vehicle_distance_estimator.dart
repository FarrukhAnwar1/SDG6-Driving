// Identifies a lead vehicle and estimates its distance using camera geometry.

import 'dart:math' as math;
import 'dart:ui';

enum FollowingDistanceStatus {
  waiting,
  confirming,
  tracking,
  noVehicle,
  unreliable,
  unavailable,
  paused,
}

class VehicleDetection {
  const VehicleDetection({
    required this.label,
    required this.confidence,
    required this.normalizedBox,
  });

  final String label;
  final double confidence;
  // Coordinates in the upright, uncropped camera frame, all between 0 and 1.
  final Rect normalizedBox;
}

class FollowingDistanceMeasurement {
  const FollowingDistanceMeasurement({
    required this.timestamp,
    required this.status,
    this.distanceMeters,
    this.leadVehicleId,
  });

  final DateTime timestamp;
  final FollowingDistanceStatus status;
  final double? distanceMeters;
  final String? leadVehicleId;
}

// Monocular baseline: distance = assumed vehicle width * normalized focal
// length / normalized box width. The camera supplies focal length for the
// upright analysis frame; preview dimensions never enter the calculation.
class VehicleDistanceEstimator {
  VehicleDistanceEstimator({required this.normalizedFocalLength})
    : assert(normalizedFocalLength > 0 && normalizedFocalLength.isFinite);

  factory VehicleDistanceEstimator.fromHorizontalFieldOfView(double degrees) {
    assert(degrees > 0 && degrees < 180);
    return VehicleDistanceEstimator(
      normalizedFocalLength: 1 / (2 * math.tan(degrees * math.pi / 360)),
    );
  }

  final double normalizedFocalLength;
  static int _nextTrackerId = 0;
  final int _trackerId = ++_nextTrackerId;
  static const double minimumConfidence = 0.3;
  static const double immediateConfidence = 0.6;
  static const Map<String, double> _vehicleWidthsMeters = {
    'car': 1.8,
    'motorcycle': 0.8,
    'bus': 2.5,
    'truck': 2.5,
  };

  VehicleDetection? _previousVehicle;
  double? _previousDistance;
  DateTime? _previousTimestamp;
  DateTime? _firstSeen;
  int _observations = 0;
  bool _confirmed = false;
  final List<double> _recentDistances = [];
  int _trackId = 0;

  FollowingDistanceMeasurement estimate({
    required Iterable<VehicleDetection> detections,
    required DateTime timestamp,
  }) {
    if (_previousTimestamp != null && !timestamp.isAfter(_previousTimestamp!)) {
      return FollowingDistanceMeasurement(
        timestamp: timestamp,
        status: FollowingDistanceStatus.unreliable,
      );
    }
    final candidates = <({VehicleDetection detection, double distance})>[];
    var sawUnreliableVehicle = false;
    for (final detection in detections) {
      final assumedWidth = _vehicleWidthsMeters[detection.label.toLowerCase()];
      if (assumedWidth == null) continue;
      final box = detection.normalizedBox;
      if (!box.left.isFinite ||
          !box.top.isFinite ||
          !box.right.isFinite ||
          !box.bottom.isFinite) {
        sawUnreliableVehicle = true;
        continue;
      }
      // Filter adjacent traffic before testing quality: an uncertain or
      // clipped car in another lane must not make a clear scene unreliable.
      // A fixed vertical cutoff is unsuitable for different dashboard mounts.
      if (box.center.dx < 0.35 || box.center.dx > 0.65) continue;
      if (detection.confidence < minimumConfidence) continue;
      if (!detection.confidence.isFinite ||
          detection.confidence > 1 ||
          box.left <= 0.01 ||
          box.right >= 0.99 ||
          box.top <= 0.01 ||
          box.bottom >= 0.99 ||
          box.width < 0.02 ||
          box.height <= 0) {
        sawUnreliableVehicle = true;
        continue;
      }
      final distance = assumedWidth * normalizedFocalLength / box.width;
      if (!distance.isFinite || distance < 1 || distance > 120) {
        sawUnreliableVehicle = true;
        continue;
      }
      candidates.add((detection: detection, distance: distance));
    }
    if (candidates.isEmpty) {
      reset();
      return FollowingDistanceMeasurement(
        timestamp: timestamp,
        status: sawUnreliableVehicle
            ? FollowingDistanceStatus.unreliable
            : FollowingDistanceStatus.noVehicle,
      );
    }
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    final selected = candidates.first;
    final previous = _previousVehicle;
    final isContinuous =
        _previousTimestamp != null &&
        timestamp.isAfter(_previousTimestamp!) &&
        timestamp.difference(_previousTimestamp!) <= const Duration(seconds: 1);
    final isSameVehicle =
        isContinuous &&
        previous != null &&
        previous.label.toLowerCase() ==
            selected.detection.label.toLowerCase() &&
        _intersectionOverUnion(
              previous.normalizedBox,
              selected.detection.normalizedBox,
            ) >=
            0.25;
    // Reject a single implausible jump rather than letting an unstable box
    // extend an unsafe streak. The next observation gets a new grace window.
    if (isSameVehicle &&
        _previousDistance != null &&
        (selected.distance / _previousDistance! > 1.6 ||
            selected.distance / _previousDistance! < 0.6)) {
      reset();
      return FollowingDistanceMeasurement(
        timestamp: timestamp,
        status: FollowingDistanceStatus.unreliable,
      );
    }
    if (!isSameVehicle) {
      _trackId++;
      _firstSeen = timestamp;
      _observations = 0;
      _confirmed = false;
      _recentDistances.clear();
    }
    _observations++;
    // Nano-model scores on small road vehicles often fall below 0.6. Accept
    // those only after three overlapping observations across at least 300 ms;
    // an isolated lower-confidence hit cannot start grading.
    _confirmed =
        _confirmed ||
        selected.detection.confidence >= immediateConfidence ||
        (_observations >= 3 &&
            timestamp.difference(_firstSeen!) >=
                const Duration(milliseconds: 300));
    _previousVehicle = selected.detection;
    _previousDistance = selected.distance;
    _previousTimestamp = timestamp;
    _recentDistances.add(selected.distance);
    if (_recentDistances.length > 3) _recentDistances.removeAt(0);
    if (!_confirmed) {
      return FollowingDistanceMeasurement(
        timestamp: timestamp,
        status: FollowingDistanceStatus.confirming,
      );
    }
    final sortedDistances = [..._recentDistances]..sort();
    final middle = sortedDistances.length ~/ 2;
    final filteredDistance = sortedDistances.length.isOdd
        ? sortedDistances[middle]
        : (sortedDistances[middle - 1] + sortedDistances[middle]) / 2;
    return FollowingDistanceMeasurement(
      timestamp: timestamp,
      status: FollowingDistanceStatus.tracking,
      distanceMeters: filteredDistance,
      leadVehicleId: 'vehicle-$_trackerId-$_trackId',
    );
  }

  void reset() {
    _previousVehicle = null;
    _previousDistance = null;
    _previousTimestamp = null;
    _firstSeen = null;
    _observations = 0;
    _confirmed = false;
    _recentDistances.clear();
  }

  double _intersectionOverUnion(Rect a, Rect b) {
    final overlap = a.intersect(b);
    if (overlap.width <= 0 || overlap.height <= 0) return 0;
    final intersection = overlap.width * overlap.height;
    return intersection /
        (a.width * a.height + b.width * b.height - intersection);
  }
}
