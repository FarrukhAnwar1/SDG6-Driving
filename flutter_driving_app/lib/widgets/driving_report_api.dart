// Sends a driving report to the backend.
// Can also read a driver's trip history.
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'auth_storage.dart';
import 'driving_report_policy.dart';
import 'driving_report_summary.dart';

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
  }) async {
    if (!canGenerateDrivingReport(milesDriven)) {
      return DrivingReportResult.failure(
        'Drive at least 1 mile to generate and save a driving report.',
      );
    }

    final token = await AuthStorage.readToken();

    if (token == null) {
      return DrivingReportResult.failure('Not logged in.');
    }

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

  // Reads the latest 100 reports, including each report's violations.
  // Preserves the API's newest-first order (reportDate, then id).
  static Future<DrivingReportHistoryResult> fetchHistory() async {
    try {
      final token = await AuthStorage.readToken();

      if (token == null) {
        return DrivingReportHistoryResult.failure('Not logged in.');
      }

      final response = await http.get(
        Uri.parse(
          '${ApiConfig.baseUrl}/driving-reports',
        ).replace(queryParameters: {'limit': '$historyLimit'}),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      debugPrint('DRIVING REPORT HISTORY STATUS: ${response.statusCode}');

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final reports = (decoded['reports'] as List<dynamic>)
            .map(
              (item) =>
                  DrivingReportSummary.fromJson(item as Map<String, dynamic>),
            )
            .toList();
        return DrivingReportHistoryResult.success(reports);
      } else if (response.statusCode == 401) {
        return DrivingReportHistoryResult.failure(
          'Session expired. Please log in again.',
        );
      } else {
        return DrivingReportHistoryResult.failure(
          'Failed to load trip history. Please try again.',
        );
      }
    } on FormatException {
      return DrivingReportHistoryResult.failure(
        'Could not read trip history. Please try again.',
      );
    } on TypeError {
      return DrivingReportHistoryResult.failure(
        'Could not read trip history. Please try again.',
      );
    } catch (_) {
      return DrivingReportHistoryResult.failure(
        'Could not connect to backend.',
      );
    }
  }
}
