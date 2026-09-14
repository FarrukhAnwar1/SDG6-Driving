// Model of completed trip information, which can be passed to the Driving Report screen
// and subsequently be uploaded to the database via the Driving Report Upload API endpoint
import 'package:flutter/foundation.dart';
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

  // Average of all other grades
  final double overallGrade;

  // Proper Speed grade. Each violation holds its start/end time, the posted
  // limit and peak speed of the streak, and coordinates where it began.
  final double properSpeedGrade;
  final List<SpeedingViolation> speedingViolations;

  // Smooth Braking / Smooth Accelerating / Smooth Turning grades.
  // Each violations list holds one entry per violation,
  // with its start/end time, peak g-force, and coordinates where it began.
  final double brakingGrade;
  final double acceleratingGrade;
  final double turningGrade;
  final List<SmoothnessViolation> brakingViolations;
  final List<SmoothnessViolation> acceleratingViolations;
  final List<SmoothnessViolation> turningViolations;

  // Focused Driving grade. Each violation holds its start/end time, length, the speed the
  // vehicle was going when the app was left, and coordinates where it began.
  final double focusedDrivingGrade;
  final List<FocusedDrivingViolation> focusedDrivingViolations;

  const TripSummary({
    required this.startTime,
    required this.endTime,
    required this.elapsed,
    required this.milesDriven,
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
}