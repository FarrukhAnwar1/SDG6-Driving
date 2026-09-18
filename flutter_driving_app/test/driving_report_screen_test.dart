// Widget tests for DrivingReportScreen, including the minimum trip distance requirement and the upload process
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/driving_report_screen.dart';
import 'package:flutter_driving_app/screens/home_screen.dart';
import 'package:flutter_driving_app/widgets/driving_report_api.dart';
import 'package:flutter_driving_app/widgets/driving_report_policy.dart';
import 'package:flutter_driving_app/widgets/trip_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

TripSummary trip(double miles) => TripSummary(
  startTime: DateTime.utc(2026, 9, 18, 10),
  endTime: DateTime.utc(2026, 9, 18, 10, 5),
  elapsed: const Duration(minutes: 5),
  milesDriven: miles,
  overallGrade: 74,
  properSpeedGrade: 90,
  speedingViolations: const [],
  brakingGrade: 80,
  acceleratingGrade: 60,
  turningGrade: 100,
  brakingViolations: const [],
  acceleratingViolations: const [],
  turningViolations: const [],
  focusedDrivingGrade: 40,
  focusedDrivingViolations: const [],
);

Future<DrivingReportResult> upload(double miles) {
  final summary = trip(miles);
  return DrivingReportApi.sendReport(
    startTime: summary.startTime,
    endTime: summary.endTime,
    milesDriven: summary.milesDriven,
    overallGrade: summary.overallGrade,
    properSpeedGrade: summary.properSpeedGrade,
    brakingGrade: summary.brakingGrade,
    acceleratingGrade: summary.acceleratingGrade,
    turningGrade: summary.turningGrade,
    focusedDrivingGrade: summary.focusedDrivingGrade,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final defaultRequirement = enforceMinimumTripDistance;

  setUp(() {
    enforceMinimumTripDistance = true;
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  tearDown(() => enforceMinimumTripDistance = defaultRequirement);

  test('minimum distance defaults to enabled', () {
    expect(defaultRequirement, isTrue);
  });

  test(
    'API rejects short trips and accepts exactly one mile and above',
    () async {
      final uploadedMiles = <double>[];
      await http.runWithClient(
        () async {
          for (final miles in [0.0, 0.5, 0.999999, 1.0, 1.2]) {
            final result = await upload(miles);
            expect(result.success, miles >= 1.0);
            if (miles < 1.0) {
              expect(result.errorMessage, contains('at least 1 mile'));
            }
          }
        },
        () => MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/driving-reports');
          expect(request.headers['Authorization'], 'Bearer test-token');
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          uploadedMiles.add((payload['tripDistanceMiles'] as num).toDouble());
          expect(payload['focusGrade'], 40);
          expect(payload['brakingGrade'], 80);
          expect(payload['accelerationGrade'], 60);
          expect(payload['turningGrade'], 100);
          return http.Response('{}', 201);
        }),
      );
      expect(uploadedMiles, [1.0, 1.2]);
    },
  );

  for (final miles in [0.0, 0.5, 0.999999]) {
    testWidgets(
      'trip of $miles miles shows requirement without a report or upload',
      (tester) async {
        var requests = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(home: DrivingReportScreen(summary: trip(miles))),
            );
            await tester.pumpAndSettle();

            expect(find.text('Trip too short for a report'), findsOneWidget);
            expect(
              find.textContaining('Drive at least 1 mile'),
              findsOneWidget,
            );
            expect(
              find.textContaining('no report was generated or uploaded'),
              findsOneWidget,
            );
            expect(find.textContaining('Overall Score:'), findsNothing);
            expect(find.text('Smoothness Score'), findsNothing);
            expect(find.text('Focused Driving Score'), findsNothing);
            expect(find.text('Helpful Tip!'), findsNothing);
            expect(find.text('Retry'), findsNothing);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.text('1.00 miles'), findsNothing);
            expect(
              find.widgetWithText(FilledButton, 'Return Home').hitTestable(),
              findsOneWidget,
            );
            expect(requests, 0);
            expect(tester.takeException(), isNull);
          },
          () => MockClient((_) async {
            requests++;
            return http.Response('{}', 201);
          }),
        );
      },
    );
  }

  testWidgets(
    'one-mile report shows grades and keeps Return Home fixed while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(home: DrivingReportScreen(summary: trip(1.0))),
          );
          await tester.pumpAndSettle();

          expect(find.text('Trip too short for a report'), findsNothing);
          expect(find.text('Overall Score: 74%'), findsOneWidget);
          final smoothness = find.widgetWithText(ListTile, 'Smoothness Score');
          expect(
            find.descendant(of: smoothness, matching: find.text('80%')),
            findsOneWidget,
          );
          expect(
            find.text('Braking: 80%\nAcceleration: 60%\nTurning: 100%'),
            findsOneWidget,
          );
          final focus = find.widgetWithText(ListTile, 'Focused Driving Score');
          expect(
            find.descendant(of: focus, matching: find.text('40%')),
            findsOneWidget,
          );

          final button = find.widgetWithText(FilledButton, 'Return Home');
          final initialPosition = tester.getTopLeft(button);
          expect(button.hitTestable(), findsOneWidget);
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(0, -600),
          );
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(button), initialPosition);
          expect(button.hitTestable(), findsOneWidget);
          expect(requests, 1);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((_) async {
          requests++;
          return http.Response('{}', 201);
        }),
      );
    },
  );

  testWidgets('development toggle enables both short-trip report and upload', (
    tester,
  ) async {
    enforceMinimumTripDistance = false;
    var requests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(home: DrivingReportScreen(summary: trip(0.2))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Trip too short for a report'), findsNothing);
        expect(find.text('Overall Score: 74%'), findsOneWidget);
        expect(find.text('Smoothness Score'), findsOneWidget);
        expect(find.text('Focused Driving Score'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        expect(requests, 1);
      },
      () => MockClient((request) async {
        requests++;
        expect(jsonDecode(request.body)['tripDistanceMiles'], 0.2);
        return http.Response('{}', 201);
      }),
    );
  });

  testWidgets('eligible report can retry a failed upload', (tester) async {
    var requests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(home: DrivingReportScreen(summary: trip(1.0))),
        );
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsNothing);
        expect(requests, 2);
      },
      () => MockClient((_) async {
        requests++;
        return http.Response('{}', requests == 1 ? 500 : 201);
      }),
    );
  });

  testWidgets('Return Home works after a short trip', (tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(home: DrivingReportScreen(summary: trip(0.5))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Return Home'));
        await tester.pumpAndSettle();
        expect(find.byType(HomePage), findsOneWidget);
        expect(find.text('Welcome, driver!'), findsOneWidget);
        expect(find.byType(DrivingReportScreen), findsNothing);
      },
      () => MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/me');
        return http.Response('{"username":"driver"}', 200);
      }),
    );
  });
}
