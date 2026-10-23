// Tests grade averages and consistent results across summaries, reports, and uploads.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/driving_report_screen.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/driving_reports/driving_report_api.dart';
import 'package:flutter_driving_app/widgets/grading/focused_driving_grading_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_grading_service.dart';
import 'package:flutter_driving_app/widgets/grading/overall_driving_grade.dart';
import 'package:flutter_driving_app/widgets/driving_reports/pending_report_store.dart';
import 'package:flutter_driving_app/widgets/driving_reports/trip_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fixtures/auth_fixtures.dart';

final _start = DateTime.utc(2026, 10, 22, 10);
final _followingViolation = FollowingDistanceViolation(
  startTime: _start,
  endTime: _start.add(const Duration(seconds: 7)),
  latitude: 40,
  longitude: -75,
  minimumHeadwaySeconds: 1,
  minimumDistanceMeters: 13.4,
  speedAtStartMph: 30,
  penalizedDuration: const Duration(seconds: 2),
);
final _focusViolation = FocusedDrivingViolation(
  startTime: _start,
  endTime: _start.add(const Duration(seconds: 7)),
  duration: const Duration(seconds: 7),
  speedAtStartMph: 30,
  latitude: 40,
  longitude: -75,
);

TripSummary _trip(DrivingMode mode) => TripSummary(
  startTime: _start,
  endTime: _start.add(const Duration(minutes: 5)),
  elapsed: const Duration(minutes: 5),
  milesDriven: 2,
  drivingMode: mode,
  overallGrade: overallDrivingGrade(
    properSpeedGrade: 80,
    brakingGrade: 70,
    acceleratingGrade: 60,
    turningGrade: 50,
    focusedDrivingGrade: mode.tracksFocus ? 40 : null,
    followingDistanceGrade: mode.tracksFollowingDistance ? 0 : null,
  ),
  properSpeedGrade: 80,
  brakingGrade: 70,
  acceleratingGrade: 60,
  turningGrade: 50,
  focusedDrivingGrade: 40,
  followingDistanceGrade: 0,
  speedingViolations: const [],
  brakingViolations: const [],
  acceleratingViolations: const [],
  turningViolations: const [],
  focusedDrivingViolations: [_focusViolation],
  followingDistanceViolations: [_followingViolation],
);

Future<DrivingReportResult> _send(TripSummary summary) =>
    DrivingReportApi.sendReport(
      clientTripId: summary.clientTripId,
      startTime: summary.startTime,
      endTime: summary.endTime,
      milesDriven: summary.milesDriven,
      drivingMode: summary.drivingMode,
      overallGrade: summary.overallGrade,
      properSpeedGrade: summary.properSpeedGrade,
      brakingGrade: summary.brakingGrade,
      acceleratingGrade: summary.acceleratingGrade,
      turningGrade: summary.turningGrade,
      focusedDrivingGrade: summary.focusedDrivingGrade,
      followingDistanceGrade: summary.followingDistanceGrade,
      focusedDrivingViolations: summary.focusedDrivingViolations,
      followingDistanceViolations: summary.followingDistanceViolations,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'access_token': testAccessToken(),
    }),
  );

  for (final (mode, expected) in [
    (DrivingMode.normal, 50.0),
    (DrivingMode.navigation, 52.0),
    (DrivingMode.pocket, 65.0),
  ]) {
    test(
      '${mode.apiValue} averages 6/5/4 categories preserving a real zero',
      () {
        final summary = _trip(mode);
        expect(summary.overallGrade, expected);
        expect(summary.smoothnessGrade, 60);
        expect(summary.focusedDrivingGrade, mode.tracksFocus ? 40 : isNull);
        expect(
          summary.focusedDrivingViolations,
          mode.tracksFocus ? hasLength(1) : isEmpty,
        );
        expect(
          summary.followingDistanceGrade,
          mode.tracksFollowingDistance ? 0 : isNull,
        );
        expect(
          summary.followingDistanceViolations,
          mode.tracksFollowingDistance ? hasLength(1) : isEmpty,
        );
        expect(DrivingModeJson.fromApiValue(mode.apiValue), mode);
      },
    );

    test(
      '${mode.apiValue} uploads the finalized nullable grades and supported violations',
      () async {
        final summary = _trip(mode);
        final result = await http.runWithClient(
          () => _send(summary),
          () => MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['clientTripId'], summary.clientTripId);
            expect(body['drivingMode'], mode.apiValue);
            expect(body['overallGrade'], expected);
            expect(body.containsKey('followingDistanceGrade'), isTrue);
            expect(
              body['followingDistanceGrade'],
              mode.tracksFollowingDistance ? 0 : isNull,
            );
            expect(body['focusGrade'], mode.tracksFocus ? 40 : isNull);
            final violations = body['violations'] as List;
            expect(
              violations.where((v) => v['violationType'] == 'Focused Driving'),
              mode.tracksFocus ? hasLength(1) : isEmpty,
            );
            final distance = violations.where(
              (v) => v['violationType'] == 'Adequate Following Distance',
            );
            expect(
              distance,
              mode.tracksFollowingDistance ? hasLength(1) : isEmpty,
            );
            if (mode.tracksFollowingDistance) {
              expect(distance.single['startTime'], _start.toIso8601String());
              expect(
                distance.single['endTime'],
                _followingViolation.endTime.toIso8601String(),
              );
              expect(distance.single['latitude'], 40);
              expect(distance.single['longitude'], -75);
            }
            return http.Response('{}', 201);
          }),
        );
        expect(result.success, isTrue);
      },
    );

    testWidgets(
      '${mode.apiValue} displays tracked grades and mode consistently with uploads',
      (tester) async {
        Map<String, dynamic>? payload;
        final summary = _trip(mode);
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(home: DrivingReportScreen(summary: summary)),
            );
            await tester.pumpAndSettle();
            expect(payload!['overallGrade'], summary.overallGrade);
            expect(
              find.text('Overall Score: ${expected.toStringAsFixed(0)}%'),
              findsOneWidget,
            );
            expect(
              find.text(switch (mode) {
                DrivingMode.normal => 'Regular',
                DrivingMode.navigation => 'Navigation',
                DrivingMode.pocket => 'Pocket',
              }),
              findsOneWidget,
            );
            final row = find.widgetWithText(
              ListTile,
              'Adequate Following Distance Score',
            );
            expect(
              find.text('Focused Driving Score'),
              mode.tracksFocus ? findsOneWidget : findsNothing,
            );
            if (mode.tracksFollowingDistance) {
              expect(
                find.descendant(of: row, matching: find.text('0%')),
                findsOneWidget,
              );
              expect(find.textContaining('Leave a longer gap'), findsOneWidget);
            } else {
              expect(row, findsNothing);
              expect(find.text('Not tracked'), findsNothing);
            }
            expect(find.text('Following Distance Violations'), findsNothing);
            expect(
              find.text('Following distances are camera estimates.'),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          },
          () => MockClient((request) async {
            payload = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{}', 201);
          }),
        );
      },
    );
  }

  test('summary results cannot be changed after construction', () {
    final summary = _trip(DrivingMode.normal);
    expect(
      () => summary.followingDistanceViolations.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => summary.focusedDrivingViolations.clear(),
      throwsUnsupportedError,
    );
    expect(() => summary.speedingViolations.clear(), throwsUnsupportedError);
  });

  test(
    'retry preserves the new category, violations, mode and trip ID byte-for-byte',
    () async {
      final summary = _trip(DrivingMode.navigation);
      final requests = <String>[];
      await http.runWithClient(
        () async {
          final result = await _send(summary);
          expect(result.savedLocally, isTrue);
          final stored = (await PendingReportStore.read('1')).single;
          expect(stored['clientTripId'], summary.clientTripId);
          expect(stored['followingDistanceGrade'], 0);
          expect(stored['focusGrade'], isNull);
          final retry = await DrivingReportApi.retryPendingReports();
          expect(retry.remaining, 0);
        },
        () => MockClient((request) async {
          requests.add(request.body);
          if (requests.length == 1) throw http.ClientException('Lost response');
          return http.Response('{}', 200);
        }),
      );
      expect(requests, hasLength(2));
      expect(requests.first, requests.last);
    },
  );
}
