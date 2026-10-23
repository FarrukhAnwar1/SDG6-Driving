// Model of completed trip information, which can be passed to the Driving Report screen
// and subsequently be uploaded to the database via the Driving Report Upload API endpoint
import 'package:flutter/foundation.dart';

import '../driving/driving_mode.dart';
import '../grading/speed_grading_service.dart';
import '../grading/smoothness_grading_service.dart';
import '../grading/focused_driving_grading_service.dart';
import '../following_distance/following_distance_grading_service.dart';
import 'trip_id.dart';

@immutable
class TripSummary {
  final String clientTripId;
  final String? ownerUserId;
  // Basic trip information
  final DateTime startTime;
  final DateTime endTime;
  final Duration elapsed;
  final double milesDriven;
  final DrivingMode drivingMode;

  // Average of all graded categories for this mode
  final double overallGrade;

  // Proper Speed grade and its recorded violations
  final double properSpeedGrade;
  final List<SpeedingViolation> speedingViolations;

  // Smooth Braking / Smooth Accelerating / Smooth Turning grades.
  final double brakingGrade;
  final double acceleratingGrade;
  final double turningGrade;
  final List<SmoothnessViolation> brakingViolations;
  final List<SmoothnessViolation> acceleratingViolations;
  final List<SmoothnessViolation> turningViolations;

  // Focused Driving grade. Null when drivingMode doesn't support focus
  // grading (e.g. navigation).
  final double? focusedDrivingGrade;
  final List<FocusedDrivingViolation> focusedDrivingViolations;

  // Null in Pocket mode; camera interruptions retain the last earned score.
  final double? followingDistanceGrade;
  final List<FollowingDistanceViolation> followingDistanceViolations;

  TripSummary({
    String? clientTripId,
    this.ownerUserId,
    required this.startTime,
    required this.endTime,
    required this.elapsed,
    required this.milesDriven,
    required this.drivingMode,
    required this.overallGrade,
    required this.properSpeedGrade,
    required List<SpeedingViolation> speedingViolations,
    required this.brakingGrade,
    required this.acceleratingGrade,
    required this.turningGrade,
    required List<SmoothnessViolation> brakingViolations,
    required List<SmoothnessViolation> acceleratingViolations,
    required List<SmoothnessViolation> turningViolations,
    required double? focusedDrivingGrade,
    required List<FocusedDrivingViolation> focusedDrivingViolations,
    double? followingDistanceGrade,
    List<FollowingDistanceViolation> followingDistanceViolations = const [],
  }) : clientTripId = clientTripId ?? newClientTripId(),
       speedingViolations = List.unmodifiable(speedingViolations),
       brakingViolations = List.unmodifiable(brakingViolations),
       acceleratingViolations = List.unmodifiable(acceleratingViolations),
       turningViolations = List.unmodifiable(turningViolations),
       focusedDrivingGrade = drivingMode.tracksFocus
           ? focusedDrivingGrade
           : null,
       focusedDrivingViolations = List.unmodifiable(
         drivingMode.tracksFocus ? focusedDrivingViolations : const [],
       ),
       followingDistanceGrade = drivingMode.tracksFollowingDistance
           ? followingDistanceGrade
           : null,
       followingDistanceViolations = List.unmodifiable(
         drivingMode.tracksFollowingDistance
             ? followingDistanceViolations
             : const [],
       );

  // Combined average of the three smoothness categories
  double get smoothnessGrade =>
      (brakingGrade + acceleratingGrade + turningGrade) / 3;
}
