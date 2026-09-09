// Sends a driving report to the backend.
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'auth_storage.dart';

class DrivingReportResult {
  final bool success;
  final String? errorMessage;

  DrivingReportResult.success() : success = true, errorMessage = null;
  DrivingReportResult.failure(this.errorMessage) : success = false;
}

class DrivingReportApi {
  DrivingReportApi._();

  static Future<DrivingReportResult> sendReport({
    required DateTime startTime,
    required DateTime endTime,
    required Duration elapsed,
    required double milesDriven,
    required double overallGrade,
    required double properSpeedGrade,
  }) async {
    final token = await AuthStorage.readToken();

    if (token == null) {
      return DrivingReportResult.failure('Not logged in.');
    }

    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/reports'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'start_time': startTime.toIso8601String(),
          'end_time': endTime.toIso8601String(),
          'elapsed_seconds': elapsed.inSeconds,
          'miles_driven': milesDriven,
          'overall_grade': overallGrade,
          'proper_speed_grade': properSpeedGrade,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return DrivingReportResult.success();
      } else if (response.statusCode == 401) {
        return DrivingReportResult.failure('Session expired. Please log in again.');
      } else {
        return DrivingReportResult.failure('Failed to send report. Please try again.');
      }
    } catch (_) {
      return DrivingReportResult.failure('Could not connect to backend.');
    }
  }
}