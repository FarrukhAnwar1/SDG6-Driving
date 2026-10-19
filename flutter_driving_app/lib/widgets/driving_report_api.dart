// Sends a driving report to the backend, and fetches saved report history.
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'auth_storage.dart';
import 'driving_mode.dart';
import 'driving_report_policy.dart';
import 'driving_report_summary.dart';
import 'speed_grading_service.dart';
import 'smoothness_grading_service.dart';
import 'focused_driving_grading_service.dart';
import 'pending_report_store.dart';

class DrivingReportResult {
  final bool success;
  final String? errorMessage;
  final bool savedLocally;

  DrivingReportResult.success()
    : success = true,
      errorMessage = null,
      savedLocally = false;
  DrivingReportResult.failure(this.errorMessage, {this.savedLocally = false})
    : success = false;
}

class PendingReportRetryResult {
  final int remaining;
  final String? errorMessage;
  const PendingReportRetryResult(this.remaining, [this.errorMessage]);
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
  static final Map<String, Future<void>> _uploads = {};

  static Future<T> _serializeUpload<T>(
    String owner,
    Future<T> Function() operation,
  ) {
    final result = (_uploads[owner] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _uploads[owner] = tail;
    return result.whenComplete(() {
      if (identical(_uploads[owner], tail)) _uploads.remove(owner);
    });
  }

  static Future<DrivingReportResult> sendReport({
    required String clientTripId,
    String? ownerUserId,
    required DateTime startTime,
    required DateTime endTime,
    required double milesDriven,
    required DrivingMode drivingMode,
    required double overallGrade,
    required double properSpeedGrade,
    required double brakingGrade,
    required double acceleratingGrade,
    required double turningGrade,
    required double? focusedDrivingGrade,
    List<SpeedingViolation> speedingViolations = const [],
    List<SmoothnessViolation> brakingViolations = const [],
    List<SmoothnessViolation> acceleratingViolations = const [],
    List<SmoothnessViolation> turningViolations = const [],
    List<FocusedDrivingViolation> focusedDrivingViolations = const [],
    void Function()? onSavedLocally,
  }) async {
    if (!canGenerateDrivingReport(milesDriven)) {
      return DrivingReportResult.failure(
        'Trip must be at least 1 mile to generate a report.',
      );
    }

    final violations = [
      ..._speedingViolationsJson(speedingViolations),
      ..._smoothnessViolationsJson(brakingViolations),
      ..._smoothnessViolationsJson(acceleratingViolations),
      ..._smoothnessViolationsJson(turningViolations),
      ..._focusedDrivingViolationsJson(focusedDrivingViolations),
    ];

    final payload = <String, dynamic>{
      'clientTripId': clientTripId,
      'startedAt': startTime.toUtc().toIso8601String(),
      'endedAt': endTime.toUtc().toIso8601String(),
      'tripDistanceMiles': milesDriven,
      'drivingMode': drivingMode.apiValue,
      'overallGrade': overallGrade,
      'speedGrade': properSpeedGrade,
      'brakingGrade': brakingGrade,
      'accelerationGrade': acceleratingGrade,
      'turningGrade': turningGrade,
      'focusGrade': focusedDrivingGrade,
      'violations': violations,
    };
    final String owner;
    try {
      final id =
          ownerUserId ??
          AuthStorage.userIdFromToken(await AuthStorage.readToken());
      if (id == null) {
        return DrivingReportResult.failure(
          'Please log in to save this report.',
        );
      }
      owner = id;
      await PendingReportStore.put(owner, payload);
    } catch (_) {
      return DrivingReportResult.failure(
        'Could not save this report on your device. Stay here and try again.',
      );
    }
    onSavedLocally?.call();
    return _serializeUpload(owner, () => _uploadSavedReport(owner, payload));
  }

  static Future<DrivingReportResult> _uploadSavedReport(
    String owner,
    Map<String, dynamic> payload,
  ) async {
    try {
      final pending = await PendingReportStore.read(owner);
      final tripId = payload['clientTripId'] as String;
      if (!pending.any((report) => report['clientTripId'] == tripId)) {
        return DrivingReportResult.success();
      }
      final token = await AuthStorage.readToken();
      if (AuthStorage.userIdFromToken(token) != owner) {
        return DrivingReportResult.failure(
          'Report saved on this device. Sign in with the original account to upload it.',
          savedLocally: true,
        );
      }
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/driving-reports'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200 || response.statusCode == 201) {
        await PendingReportStore.remove(owner, tripId);
        return DrivingReportResult.success();
      } else if (response.statusCode == 401) {
        return DrivingReportResult.failure(
          'Report saved on this device. Log in again to upload it.',
          savedLocally: true,
        );
      } else {
        return DrivingReportResult.failure(
          'Report saved on this device. Upload failed; we will retry from Home.',
          savedLocally: true,
        );
      }
    } catch (_) {
      return DrivingReportResult.failure(
        'Report saved on this device. We will retry uploading from Home.',
        savedLocally: true,
      );
    }
  }

  static Future<PendingReportRetryResult> retryPendingReports() async {
    final owner = AuthStorage.userIdFromToken(await AuthStorage.readToken());
    if (owner == null) return const PendingReportRetryResult(0);
    return _serializeUpload(owner, () async {
      String? error;
      for (final payload in await PendingReportStore.read(owner)) {
        final result = await _uploadSavedReport(owner, payload);
        if (!result.success) {
          error = result.errorMessage;
          break;
        }
      }
      return PendingReportRetryResult(
        (await PendingReportStore.read(owner)).length,
        error,
      );
    });
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
