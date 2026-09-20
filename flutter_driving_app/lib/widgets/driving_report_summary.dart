// Models a single saved report and its nested violations
// returned by GET /driving-reports.
import 'package:flutter/foundation.dart';

@immutable
class DrivingReportSummary {
  final int id;
  // The trip's end time. Older stored reports may have no date.
  final DateTime? reportDate;
  final double tripDurationMinutes;
  final double milesDriven;
  final List<DrivingReportViolation> violations;

  final double overallGrade;
  final double properSpeedGrade;
  final double brakingGrade;
  final double acceleratingGrade;
  final double turningGrade;
  final double focusedDrivingGrade;

  const DrivingReportSummary({
    required this.id,
    required this.reportDate,
    required this.tripDurationMinutes,
    required this.milesDriven,
    required this.violations,
    required this.overallGrade,
    required this.properSpeedGrade,
    required this.brakingGrade,
    required this.acceleratingGrade,
    required this.turningGrade,
    required this.focusedDrivingGrade,
  });

  Duration get elapsed => Duration(
    microseconds: (tripDurationMinutes * Duration.microsecondsPerMinute)
        .round(),
  );

  // All six grades keyed by the label the Analytics screen displays, charts,
  // and selects in its dropdown. Centralizing this mapping means the screen,
  // the chart series, and the grade dropdown can't drift out of sync with each
  // other. Add a grade here and it shows up everywhere automatically.
  Map<String, double> get gradesByLabel => {
    'Overall': overallGrade,
    'Speed': properSpeedGrade,
    'Braking': brakingGrade,
    'Acceleration': acceleratingGrade,
    'Turning': turningGrade,
    'Focused Driving': focusedDrivingGrade,
  };

  // Read responses contain reportDate and decimal minutes, not the write
  // request's startedAt / endedAt timestamps.
  factory DrivingReportSummary.fromJson(Map<String, dynamic> json) {
    return DrivingReportSummary(
      id: json['id'] as int,
      reportDate: json['reportDate'] == null
          ? null
          : _parseReportTime(json['reportDate'] as String),
      tripDurationMinutes: (json['tripDurationMinutes'] as num).toDouble(),
      milesDriven: (json['tripDistanceMiles'] as num).toDouble(),
      violations: List.unmodifiable(
        (json['violations'] as List<dynamic>).map(
          (item) =>
              DrivingReportViolation.fromJson(item as Map<String, dynamic>),
        ),
      ),
      overallGrade: (json['overallGrade'] as num).toDouble(),
      properSpeedGrade: (json['speedGrade'] as num).toDouble(),
      brakingGrade: (json['brakingGrade'] as num).toDouble(),
      acceleratingGrade: (json['accelerationGrade'] as num).toDouble(),
      turningGrade: (json['turningGrade'] as num).toDouble(),
      focusedDrivingGrade: (json['focusGrade'] as num).toDouble(),
    );
  }
}

@immutable
class DrivingReportViolation {
  final int id;
  final String violationType;
  final String? roadName;
  final DateTime startTime;
  final DateTime endTime;

  const DrivingReportViolation({
    required this.id,
    required this.violationType,
    required this.roadName,
    required this.startTime,
    required this.endTime,
  });

  Duration get elapsed => endTime.difference(startTime);

  factory DrivingReportViolation.fromJson(Map<String, dynamic> json) {
    return DrivingReportViolation(
      id: json['id'] as int,
      violationType: json['violationType'] as String,
      roadName: json['roadName'] as String?,
      startTime: _parseReportTime(json['startTime'] as String),
      endTime: _parseReportTime(json['endTime'] as String),
    );
  }
}

DateTime _parseReportTime(String value) {
  // sendReport uploads UTC. The backend strips the offset for MySQL DATETIME,
  // so restore UTC for timestamps without an offset before displaying locally.
  final parsed = DateTime.parse(value);
  return (parsed.isUtc ? parsed : DateTime.parse('${value}Z')).toLocal();
}
