// Unit tests for the DrivingReportSummary and DrivingReportApi classes
import 'dart:convert';
import 'package:flutter_driving_app/widgets/driving_report_api.dart';
import 'package:flutter_driving_app/widgets/driving_report_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/driving_report_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  test('parses saved grades, fractional minutes and all violation types', () {
    const types = [
      'Proper Speed',
      'Smooth Braking',
      'Smooth Accelerating',
      'Smooth Turning',
      'Focused Driving',
    ];
    final report = DrivingReportSummary.fromJson(
      reportJson(
        durationMinutes: 30.01,
        violations: [
          for (var i = 0; i < types.length; i++)
            violationJson(id: i + 1, type: types[i], roadName: null),
        ],
      ),
    );

    expect(report.id, 12);
    expect(report.reportDate!.toUtc(), DateTime.utc(2026, 7, 30, 10, 30));
    expect(report.elapsed, const Duration(minutes: 30, milliseconds: 600));
    expect(report.milesDriven, 12.4);
    expect(report.gradesByLabel, {
      'Overall': 87.0,
      'Speed': 87.5,
      'Braking': 90.0,
      'Acceleration': 92.0,
      'Turning': 88.0,
      'Focused Driving': 95.0,
    });
    expect(report.violations.map((v) => v.violationType), types);
    expect(report.violations.first.id, 1);
    expect(report.violations.first.roadName, isNull);
    expect(
      report.violations.first.startTime.toUtc(),
      DateTime.utc(2026, 7, 30, 10, 5),
    );
    expect(report.violations.first.elapsed, const Duration(seconds: 18));
  });

  test('handles nullable dates, zero duration and empty violations', () {
    final report = DrivingReportSummary.fromJson(
      reportJson(reportDate: null, durationMinutes: 0),
    );
    expect(report.reportDate, isNull);
    expect(report.elapsed, Duration.zero);
    expect(report.violations, isEmpty);
  });

  test('normalizes explicit offsets and UTC dates consistently', () {
    for (final date in ['2026-07-30T10:30:00Z', '2026-07-30T06:30:00-04:00']) {
      final report = DrivingReportSummary.fromJson(
        reportJson(reportDate: date),
      );
      expect(report.reportDate!.toUtc(), DateTime.utc(2026, 7, 30, 10, 30));
    }
  });

  test(
    'requests 100 authenticated reports and retains nested violations',
    () async {
      var requests = 0;
      final result = await http.runWithClient(
        DrivingReportApi.fetchHistory,
        () => MockClient((request) async {
          requests++;
          expect(request.method, 'GET');
          expect(request.url.path, '/driving-reports');
          expect(request.url.queryParameters, {'limit': '100'});
          expect(request.headers['Authorization'], 'Bearer test-token');
          return http.Response(
            jsonEncode({
              'reports': [
                reportJson(id: 100, violations: [violationJson()]),
                reportJson(
                  id: 99,
                ), // Same end time so preserve the ID tie-break
                for (var id = 98; id > 0; id--)
                  reportJson(id: id, reportDate: '2026-07-29T10:30:00'),
              ],
            }),
            200,
          );
        }),
      );
      expect(requests, 1);
      expect(result.success, isTrue);
      expect(result.reports, hasLength(100));
      expect(result.reports.take(2).map((r) => r.id), [100, 99]);
      expect(result.reports.first.violations.single.roadName, 'Roosevelt Blvd');
      expect(result.reports[1].violations, isEmpty);
    },
  );

  test('an empty reports wrapper is a successful empty history', () async {
    final result = await http.runWithClient(
      DrivingReportApi.fetchHistory,
      () => MockClient((_) async => http.Response('{"reports": []}', 200)),
    );
    expect(result.success, isTrue);
    expect(result.reports, isEmpty);
  });

  test(
    'missing credentials do not send a request or show sample data',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final result = await http.runWithClient(
        DrivingReportApi.fetchHistory,
        () => MockClient((_) async => fail('Should not send a request')),
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, 'Not logged in.');
      expect(result.reports, isEmpty);
    },
  );

  test('reports expired sessions and server failures', () async {
    for (final status in [401, 404, 500]) {
      final result = await http.runWithClient(
        DrivingReportApi.fetchHistory,
        () => MockClient((_) async => http.Response('{}', status)),
      );
      expect(result.success, isFalse);
      expect(result.reports, isEmpty);
      expect(
        result.errorMessage,
        status == 401
            ? 'Session expired. Please log in again.'
            : 'Failed to load trip history. Please try again.',
      );
    }
  });

  test(
    'reports invalid responses distinctly from connection failures',
    () async {
      for (final body in ['not json', '[]', '{}', '{"reports": [{}]}']) {
        final result = await http.runWithClient(
          DrivingReportApi.fetchHistory,
          () => MockClient((_) async => http.Response(body, 200)),
        );
        expect(result.success, isFalse);
        expect(
          result.errorMessage,
          'Could not read trip history. Please try again.',
        );
      }
      final result = await http.runWithClient(
        DrivingReportApi.fetchHistory,
        () => MockClient((_) async => throw http.ClientException('Offline')),
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, 'Could not connect to backend.');
    },
  );
}
