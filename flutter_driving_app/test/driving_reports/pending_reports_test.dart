// Tests report persistence, upload retries, account isolation, and safe navigation.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/driving_report_screen.dart';
import 'package:flutter_driving_app/screens/home_screen.dart';
import 'package:flutter_driving_app/widgets/shared/api_config.dart';
import 'package:flutter_driving_app/widgets/auth/auth_storage.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/driving_reports/driving_report_api.dart';
import 'package:flutter_driving_app/widgets/driving_reports/pending_report_store.dart';
import 'package:flutter_driving_app/widgets/driving_reports/trip_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../fixtures/auth_fixtures.dart';

const _tripId = 'b316c158-ab2c-4401-8380-256d88b47749';
Future<DrivingReportResult> _send({
  String tripId = _tripId,
  String owner = '1',
  void Function()? onSaved,
}) => DrivingReportApi.sendReport(
  clientTripId: tripId,
  ownerUserId: owner,
  startTime: DateTime.utc(2026, 10, 18, 10),
  endTime: DateTime.utc(2026, 10, 18, 10, 10),
  milesDriven: 2,
  drivingMode: DrivingMode.normal,
  overallGrade: 90,
  properSpeedGrade: 90,
  brakingGrade: 90,
  acceleratingGrade: 90,
  turningGrade: 90,
  focusedDrivingGrade: 90,
  onSavedLocally: onSaved,
);

TripSummary _summary() => TripSummary(
  clientTripId: _tripId,
  ownerUserId: '1',
  startTime: DateTime.utc(2026, 10, 18, 10),
  endTime: DateTime.utc(2026, 10, 18, 10, 10),
  elapsed: const Duration(minutes: 10),
  milesDriven: 2,
  drivingMode: DrivingMode.normal,
  overallGrade: 90,
  properSpeedGrade: 90,
  brakingGrade: 90,
  acceleratingGrade: 90,
  turningGrade: 90,
  focusedDrivingGrade: 90,
  speedingViolations: const [],
  brakingViolations: const [],
  acceleratingViolations: const [],
  turningViolations: const [],
  focusedDrivingViolations: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'access_token': testAccessToken(),
    }),
  );

  test('a report is persisted before the network request starts', () async {
    var saved = false;
    final result = await http.runWithClient(
      () => _send(onSaved: () => saved = true),
      () => MockClient((request) async {
        expect(saved, isTrue);
        expect(jsonDecode(request.body)['clientTripId'], _tripId);
        expect(
          (await PendingReportStore.read('1')).single['clientTripId'],
          _tripId,
        );
        throw http.ClientException('Offline');
      }),
    );
    expect(result.success, isFalse);
    expect(result.savedLocally, isTrue);
    expect(
      (await PendingReportStore.read('1')).single['clientTripId'],
      _tripId,
    );
  });

  test(
    'a lost response is retried with the exact same payload and ID after restart',
    () async {
      final bodies = <String>[];
      await http.runWithClient(
        _send,
        () => MockClient((request) async {
          bodies.add(request.body);
          throw http.ClientException('Response lost after server commit');
        }),
      );
      // Recreate the plugin from its persisted contents, without an in-memory trip.
      FlutterSecureStorage.setMockInitialValues(await storage.readAll());
      final result = await http.runWithClient(
        DrivingReportApi.retryPendingReports,
        () => MockClient((request) async {
          bodies.add(request.body);
          return http.Response('{}', 201);
        }),
      );
      expect(result.remaining, 0);
      expect(bodies, hasLength(2));
      expect(bodies.first, bodies.last);
      expect(await PendingReportStore.read('1'), isEmpty);
    },
  );

  test(
    'expired-session reports survive logout and upload after the same account logs in',
    () async {
      final result = await http.runWithClient(
        _send,
        () => MockClient((_) async => http.Response('{}', 401)),
      );
      expect(result.savedLocally, isTrue);
      await AuthStorage.deleteToken();
      await http.runWithClient(
        DrivingReportApi.retryPendingReports,
        () => MockClient((_) async => fail('No request without a login')),
      );
      expect(await PendingReportStore.read('1'), hasLength(1));
      await AuthStorage.saveToken(testAccessToken());
      final retry = await http.runWithClient(
        DrivingReportApi.retryPendingReports,
        () => MockClient((_) async => http.Response('{}', 200)),
      );
      expect(retry.remaining, 0);
    },
  );

  test(
    'another account cannot see, upload, or delete the original account queue',
    () async {
      await http.runWithClient(
        _send,
        () => MockClient((_) async => http.Response('{}', 500)),
      );
      await AuthStorage.saveToken(testAccessToken(2));
      final retry = await http.runWithClient(
        DrivingReportApi.retryPendingReports,
        () => MockClient(
          (_) async => fail('Account 2 must not upload account 1 reports'),
        ),
      );
      expect(retry.remaining, 0);
      await PendingReportStore.clear('2');
      expect(await PendingReportStore.read('1'), hasLength(1));
      final result = await http.runWithClient(
        () => _send(owner: '2'),
        () => MockClient((request) async {
          expect(
            request.headers['Authorization'],
            'Bearer ${testAccessToken(2)}',
          );
          return http.Response('{}', 201);
        }),
      );
      expect(result.success, isTrue);
      expect(await PendingReportStore.read('1'), hasLength(1));
    },
  );

  test(
    'account changes before saving retain the trip for the account that drove it',
    () async {
      await AuthStorage.saveToken(testAccessToken(2));
      final result = await http.runWithClient(
        _send,
        () => MockClient(
          (_) async => fail('Must not upload using another account token'),
        ),
      );
      expect(result.savedLocally, isTrue);
      expect(await PendingReportStore.read('1'), hasLength(1));
      expect(await PendingReportStore.read('2'), isEmpty);
    },
  );

  test('concurrent queue writes preserve every report', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++)
        PendingReportStore.put('1', {'clientTripId': 'trip-$i'}),
    ]);
    expect(await PendingReportStore.read('1'), hasLength(20));
  });

  test(
    'concurrent uploads of the same trip cannot race local acknowledgments',
    () async {
      var requests = 0;
      final results = await http.runWithClient(
        () => Future.wait([_send(), _send()]),
        () => MockClient((_) async {
          requests++;
          return http.Response('{}', 201);
        }),
      );
      expect(results.every((result) => result.success), isTrue);
      expect(requests, 1);
      expect(await PendingReportStore.read('1'), isEmpty);
    },
  );

  test(
    'corrupted local storage is retained and never reported as a saved trip',
    () async {
      final key =
          'pending_reports_v1_${Uri.encodeComponent(ApiConfig.baseUrl)}_1';
      await storage.write(key: key, value: 'unreadable');
      var saved = false;
      final result = await http.runWithClient(
        () => _send(onSaved: () => saved = true),
        () => MockClient(
          (_) async => fail('Must not upload an unpersisted trip'),
        ),
      );
      expect(result.savedLocally, isFalse);
      expect(saved, isFalse);
      expect(await storage.read(key: key), 'unreadable');
    },
  );

  testWidgets(
    'leaving a failed upload retains the report and Home retries it',
    (tester) async {
      var uploads = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(home: DrivingReportScreen(summary: _summary())),
          );
          await tester.pumpAndSettle();
          expect(await PendingReportStore.read('1'), hasLength(1));
          await tester.tap(find.widgetWithText(FilledButton, 'Return Home'));
          await tester.pumpAndSettle();
          expect(find.byType(HomePage), findsOneWidget);
          expect(uploads, 2);
          expect(await PendingReportStore.read('1'), isEmpty);
        },
        () => MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              '{"id":1,"username":"driver","email":"driver@example.test"}',
              200,
            );
          }
          uploads++;
          return http.Response('{}', uploads == 1 ? 500 : 201);
        }),
      );
    },
  );

  testWidgets(
    'a durable save allows returning Home before the server responds',
    (tester) async {
      final response = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(home: DrivingReportScreen(summary: _summary())),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(await PendingReportStore.read('1'), hasLength(1));
          final button = find.widgetWithText(FilledButton, 'Return Home');
          expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
          try {
            await tester.tap(button);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.byType(HomePage), findsOneWidget);
          } finally {
            response.complete(http.Response('{}', 201));
            await tester.pumpAndSettle();
          }
          expect(await PendingReportStore.read('1'), isEmpty);
        },
        () => MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              '{"id":1,"username":"driver","email":"driver@example.test"}',
              200,
            );
          }
          return response.future;
        }),
      );
    },
  );

  testWidgets('Home retries saved reports when the app resumes', (
    tester,
  ) async {
    await http.runWithClient(
      _send,
      () => MockClient((_) async => http.Response('{}', 500)),
    );
    var online = false;
    var uploads = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: HomePage()));
        await tester.pumpAndSettle();
        expect(uploads, 1);
        expect(find.textContaining('waiting to upload'), findsOneWidget);
        online = true;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(uploads, 2);
        expect(await PendingReportStore.read('1'), isEmpty);
        expect(find.textContaining('waiting to upload'), findsNothing);
      },
      () => MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            '{"id":1,"username":"driver","email":"driver@example.test"}',
            200,
          );
        }
        uploads++;
        return http.Response('{}', online ? 201 : 500);
      }),
    );
  });

  testWidgets(
    'storage failure prevents leaving the report before a durable save',
    (tester) async {
      final key =
          'pending_reports_v1_${Uri.encodeComponent(ApiConfig.baseUrl)}_1';
      await storage.write(key: key, value: 'unreadable');
      await tester.pumpWidget(
        MaterialApp(home: DrivingReportScreen(summary: _summary())),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Return Home'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('Stay here and try again'), findsOneWidget);
    },
  );

  testWidgets('deleting an account clears only its saved reports', (
    tester,
  ) async {
    await http.runWithClient(
      _send,
      () => MockClient((_) async => http.Response('{}', 500)),
    );
    await PendingReportStore.put('2', {'clientTripId': 'another-account-trip'});
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: HomePage()));
        await tester.pumpAndSettle();
        final delete = find.widgetWithText(OutlinedButton, 'Delete Account');
        await tester.ensureVisible(delete);
        await tester.tap(delete);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(await AuthStorage.readToken(), isNull);
        expect(await PendingReportStore.read('1'), isEmpty);
        expect(await PendingReportStore.read('2'), hasLength(1));
      },
      () => MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            '{"id":1,"username":"driver","email":"driver@example.test"}',
            200,
          );
        }
        return http.Response('', request.method == 'DELETE' ? 204 : 500);
      }),
    );
  });
}
