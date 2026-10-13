// Model of completed trip information, which can be passed to the Driving Report screen
// and subsequently be uploaded to the database via the Driving Report Upload API endpoint
import 'package:flutter/foundation.dart';

import 'driving_mode.dart';
import 'speed_grading_service.dart';
import 'smoothness_grading_service.dart';
import 'focused_driving_grading_service.dart';

@immutable
class TripSummary {
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

  const TripSummary({
    required this.startTime,
    required this.endTime,
    required this.elapsed,
    required this.milesDriven,
    required this.drivingMode,
    required this.overallGrade,
    required this.properSpeedGrade,
    required this.speedingViolations,
    required this.brakingGrade,
    required this.acceleratingGrade,
    required this.turningGrade,
    required this.brakingViolations,
    required this.acceleratingViolations,
    required this.turningViolations,
    required this.focusedDrivingGrade,
    required this.focusedDrivingViolations,
  });

  // Combined average of the three smoothness categories
  double get smoothnessGrade =>
      (brakingGrade + acceleratingGrade + turningGrade) / 3;
}