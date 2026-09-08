// Model of completed trip information, which can be passed to the Driving Report screen
import 'package:flutter/foundation.dart';

@immutable
class TripSummary {
  final DateTime startTime;
  final DateTime endTime;
  final Duration elapsed;
  final double milesDriven;
  final double overallGrade;
  final double properSpeedGrade;

  const TripSummary({
    required this.startTime,
    required this.endTime,
    required this.elapsed,
    required this.milesDriven,
    required this.overallGrade,
    required this.properSpeedGrade,
  });
}
