// Describes observed vehicles and the camera's gradeable or unavailable result.

import 'dart:ui';

enum FollowingDistanceStatus {
  waiting,
  processing,
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
  // Upright, uncropped camera coordinates, normalized to 0..1.
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
