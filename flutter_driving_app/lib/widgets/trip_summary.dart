// Model of completed trip information, which can be passed to the Driving Report screen
import 'package:flutter/foundation.dart';

import 'smoothness_grading_service.dart';

@immutable
class TripSummary {
  final DateTime startTime;
  final DateTime endTime;
  final Duration elapsed;
  final double milesDriven;
  final double overallGrade;
  final double properSpeedGrade;
  final int speedingOffenseCount;
  final Duration totalSpeedingDuration;

  // Smooth Braking / Smooth Accelerating / Smooth Turning grades, alongside
  // the speed grading above. Each violations list holds one entry per violation, 
  // with its start/end time, peak g-force, and coordinates where it began
  final double brakingGrade;
  final double acceleratingGrade;
  final double turningGrade;
  final List<SmoothnessViolation> brakingViolations;
  final List<SmoothnessViolation> acceleratingViolations;
  final List<SmoothnessViolation> turningViolations;

  const TripSummary({
    required this.startTime,
    required this.endTime,
    required this.elapsed,
    required this.milesDriven,
    required this.overallGrade,
    required this.properSpeedGrade,
    required this.speedingOffenseCount,
    required this.totalSpeedingDuration,
    required this.brakingGrade,
    required this.acceleratingGrade,
    required this.turningGrade,
    required this.brakingViolations,
    required this.acceleratingViolations,
    required this.turningViolations,
  });
}
