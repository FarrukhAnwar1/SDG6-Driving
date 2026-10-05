// Sends a driving report to the backend, and fetches saved report history.
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'auth_storage.dart';
import 'driving_report_policy.dart';
import 'driving_report_summary.dart';
import 'speed_grading_service.dart';
import 'smoothness_grading_service.dart';
import 'focused_driving_grading_service.dart';

class DrivingReportResult {
  final bool success;
  final String? errorMessage;

  DrivingReportResult.success() : success = true, errorMessage = null;
  DrivingReportResult.failure(this.errorMessage) : success = false;
}

class DrivingReportHistoryResult {
  final bool success;
  final List<DrivingReportSummary> reports;
  final String? errorMessage;

  DrivingReportHistoryResult.success(this.reports)
    : success = true,
      errorMessage = null;
  DrivingReportHistoryResult.failure(this.errorMessage)
    : success = false,
      reports = const [];
}

class DrivingReportApi {
  DrivingReportApi._();

  static const int historyLimit = 100;

  static Future<DrivingReportResult> sendReport({
    required DateTime startTime,
    required DateTime endTime,
    required double milesDriven,
    required double overallGrade,
    required double properSpeedGrade,
    required double brakingGrade,
    required double acceleratingGrade,
    required double turningGrade,
    required double focusedDrivingGrade,
    List<SpeedingViolation> speedingViolations = const [],
    List<SmoothnessViolation> brakingViolations = const [],
    List<SmoothnessViolation> acceleratingViolations = const [],
    List<SmoothnessViolation> turningViolations = const [],
    List<FocusedDrivingViolation> focusedDrivingViolations = const [],
  }) async {
    if (!canGenerateDrivingReport(milesDriven)) {
      return DrivingReportResult.failure(
        'Trip must be at least 1 mile to generate a report.',
      );
    }

    final token = await AuthStorage.readToken();

    if (token == null) {
      return DrivingReportResult.failure('Not logged in.');
    }

    final violations = [
      ..._speedingViolationsJson(speedingViolations),
      ..._smoothnessViolationsJson(brakingViolations),
      ..._smoothnessViolationsJson(acceleratingViolations),
      ..._smoothnessViolationsJson(turningViolations),
      ..._focusedDrivingViolationsJson(focusedDrivingViolations),
    ];

    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/driving-reports'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'startedAt': startTime.toUtc().toIso8601String(),
          'endedAt': endTime.toUtc().toIso8601String(),
          'tripDistanceMiles': milesDriven,
          'overallGrade': overallGrade,
          'speedGrade': properSpeedGrade,
          'brakingGrade': brakingGrade,
          'accelerationGrade': acceleratingGrade,
          'turningGrade': turningGrade,
          'focusGrade': focusedDrivingGrade,
          'violations': violations,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return DrivingReportResult.success();
      } else if (response.statusCode == 401) {
        return DrivingReportResult.failure(
          'Session expired. Please log in again.',
        );
      } else {
        return DrivingReportResult.failure(
          'Failed to send report. Please try again.',
        );
      }
    } catch (_) {
      return DrivingReportResult.failure('Could not connect to backend.');
    }
  }

  static Future<DrivingReportHistoryResult> fetchHistory() async {
    final token = await AuthStorage.readToken();

    if (token == null) {
      return DrivingReportHistoryResult.failure('Not logged in.');
    }

    try {
      final uri = Uri.parse(
        '${ApiConfig.baseUrl}/driving-reports',
      ).replace(queryParameters: {'limit': '$historyLimit'});

      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 401) {
        return DrivingReportHistoryResult.failure(
          'Session expired. Please log in again.',
        );
      }

      if (response.statusCode != 200) {
        return DrivingReportHistoryResult.failure(
          'Failed to load trip history. Please try again.',
        );
      }

      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic> || decoded['reports'] is! List) {
          return DrivingReportHistoryResult.failure(
            'Could not read trip history. Please try again.',
          );
        }

        final reports = (decoded['reports'] as List)
            .map(
              (item) =>
                  DrivingReportSummary.fromJson(item as Map<String, dynamic>),
            )
            .toList();

        // Newest first; nulls last, id descending breaks same-timestamp ties.
        reports.sort((a, b) {
          if (a.reportDate == null && b.reportDate == null) {
            return b.id.compareTo(a.id);
          }
          if (a.reportDate == null) return 1;
          if (b.reportDate == null) return -1;
          final byDate = b.reportDate!.compareTo(a.reportDate!);
          return byDate != 0 ? byDate : b.id.compareTo(a.id);
        });

        return DrivingReportHistoryResult.success(reports);
      } catch (_) {
        return DrivingReportHistoryResult.failure(
          'Could not read trip history. Please try again.',
        );
      }
    } catch (_) {
      return DrivingReportHistoryResult.failure(
        'Could not connect to backend.',
      );
    }
  }

  static List<Map<String, dynamic>> _speedingViolationsJson(
    List<SpeedingViolation> violations,
  ) {
    return violations.map((v) {
      return {
        'violationType': 'Proper Speed',
        'startTime': v.startTime.toUtc().toIso8601String(),
        'endTime': v.endTime.toUtc().toIso8601String(),
        'latitude': v.latitude,
        'longitude': v.longitude,
        if (v.roadName != null) 'roadName': v.roadName,
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _smoothnessViolationsJson(
    List<SmoothnessViolation> violations,
  ) {
    return violations.map((v) {
      return {
        'violationType': v.category.label,
        'startTime': v.startTime.toUtc().toIso8601String(),
        'endTime': v.endTime.toUtc().toIso8601String(),
        'latitude': v.latitude,
        'longitude': v.longitude,
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _focusedDrivingViolationsJson(
    List<FocusedDrivingViolation> violations,
  ) {
    return violations.map((v) {
      return {
        'violationType': 'Focused Driving',
        'startTime': v.startTime.toUtc().toIso8601String(),
        'endTime': v.endTime.toUtc().toIso8601String(),
        'latitude': v.latitude,
        'longitude': v.longitude,
      };
    }).toList();
  }
}
