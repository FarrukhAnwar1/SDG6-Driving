// Selects the current lead and preserves its identity with simple box matching.

import 'dart:math' as math;

import 'following_distance_measurement.dart';
import 'following_distance_grading_service.dart';
import 'road_model_output.dart';

export 'following_distance_measurement.dart';

class VehicleDistanceEstimator {
  static const minimumConfidence = 0.25;
  static const continuationConfidence = 0.1;
  static const leadRetention = Duration(seconds: 6);
  static int _nextNamespace = 0;

  final int _namespace = ++_nextNamespace;
  int _nextLeadId = 0;
  DateTime? _timestamp;
  DateTime? _lastSeen;
  VehicleDetection? _lastLead;
  String? _leadId;
  double? _distance;

  FollowingDistanceMeasurement estimate(RoadObservation observation) {
    final timestamp = observation.timestamp;
    FollowingDistanceMeasurement missing(FollowingDistanceStatus status) {
      _distance = null;
      return FollowingDistanceMeasurement(timestamp: timestamp, status: status);
    }

    if (_timestamp != null && !timestamp.isAfter(_timestamp!)) {
      return FollowingDistanceMeasurement(
        timestamp: timestamp,
        status: FollowingDistanceStatus.unreliable,
      );
    }
    if (_lastSeen != null && timestamp.difference(_lastSeen!) > leadRetention) {
      _forgetLead();
    }
    if (_timestamp != null &&
        timestamp.difference(_timestamp!) >
            FollowingDistanceGradingService.maxSampleGap) {
      _distance = null;
    }
    _timestamp = timestamp;
    if (!observation.roadVisible) {
      return missing(FollowingDistanceStatus.waiting);
    }
    final observed = observation.vehicles
        .where((vehicle) => _validDetection(vehicle.detection))
        .toList();
    RoadVehicleObservation? matchedLead;
    var bestMatch = double.infinity;
    for (final vehicle in observed) {
      final cost = _matchCost(vehicle.detection);
      if (cost != null && cost < bestMatch) {
        matchedLead = vehicle;
        bestMatch = cost;
      }
    }
    final candidates = observed
        .where(
          (vehicle) =>
              vehicle.inEgoLane &&
              (vehicle.detection.confidence >= minimumConfidence ||
                  identical(vehicle, matchedLead)),
        )
        .toList();
    if (candidates.isEmpty) {
      if (matchedLead != null && !matchedLead.inEgoLane) {
        _forgetLead();
      }
      return missing(
        _leadId != null
            ? FollowingDistanceStatus.confirming
            : FollowingDistanceStatus.noVehicle,
      );
    }
    final measured = candidates.where(_hasUsableDepth).toList();
    if (measured.isEmpty) return missing(FollowingDistanceStatus.unreliable);
    measured.sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));
    final lead = measured.first;
    // A closer occluding vehicle with uncertain depth must not cause us to
    // grade the visible, more distant vehicle behind it instead.
    if (candidates.any(
      (vehicle) =>
          !_hasUsableDepth(vehicle) &&
          vehicle.detection.normalizedBox.bottom >=
              lead.detection.normalizedBox.bottom - 0.03,
    )) {
      return missing(FollowingDistanceStatus.unreliable);
    }
    final sameLead = identical(lead, matchedLead);
    if (!sameLead) {
      _leadId = 'lead-$_namespace-${++_nextLeadId}';
      _distance = null;
    }
    _lastLead = lead.detection;
    _lastSeen = timestamp;
    final distance = lead.distanceMeters!;
    if (_distance != null &&
        (distance / _distance! < 0.6 || distance / _distance! > 1.6)) {
      // Reject a one-frame depth jump. The next consistent observation can
      // establish a fresh baseline and grace period; never reuse stale distance.
      return missing(FollowingDistanceStatus.unreliable);
    }
    _distance = distance;
    return FollowingDistanceMeasurement(
      timestamp: timestamp,
      status: FollowingDistanceStatus.tracking,
      distanceMeters: distance,
      leadVehicleId: _leadId,
    );
  }

  bool _validDetection(VehicleDetection detection) {
    final box = detection.normalizedBox;
    return detection.confidence.isFinite &&
        detection.confidence >= continuationConfidence &&
        detection.confidence <= 1 &&
        [box.left, box.top, box.right, box.bottom].every((v) => v.isFinite) &&
        box.width > 0 &&
        box.height > 0 &&
        box.center.dx > 0 &&
        box.center.dx < 1 &&
        box.center.dy > 0 &&
        box.center.dy < 1;
  }

  bool _hasUsableDepth(RoadVehicleObservation vehicle) {
    final distance = vehicle.distanceMeters;
    return distance != null &&
        distance.isFinite &&
        distance >= 1 &&
        distance <= 150;
  }

  // Only match the last observed lead. No predicted boxes, Kalman filter,
  // assignment stage, or second-sighting gate is needed at this sampling rate.
  double? _matchCost(VehicleDetection detection) {
    final previous = _lastLead?.normalizedBox;
    if (previous == null) return null;
    final box = detection.normalizedBox;
    final widthRatio = box.width / previous.width;
    final heightRatio = box.height / previous.height;
    final width = math.max(box.width, previous.width);
    final height = math.max(box.height, previous.height);
    final dx = (box.center.dx - previous.center.dx).abs();
    final dy = (box.center.dy - previous.center.dy).abs();
    if (widthRatio < 0.4 ||
        widthRatio > 2.5 ||
        heightRatio < 0.4 ||
        heightRatio > 2.5 ||
        dx > math.max(0.06, width * 0.75) ||
        dy > math.max(0.06, height * 0.75)) {
      return null;
    }
    return dx / width +
        dy / height +
        0.25 * (math.log(widthRatio).abs() + math.log(heightRatio).abs());
  }

  void _forgetLead() {
    _lastLead = null;
    _lastSeen = null;
    _leadId = null;
    _distance = null;
  }

  void reset() {
    _timestamp = null;
    _forgetLead();
  }
}
