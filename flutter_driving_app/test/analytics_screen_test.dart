// Widget tests for the AnalyticsScreen
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/analytics_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/driving_report_fixtures.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  testWidgets('uses newest report for last drive and charts oldest first', (
    tester,
  ) async {
    // The newest trip started earlier. Sorting on a derived start time would
    // select the wrong last drive. Equal report dates must keep API ID order.
    final reports = [
      reportJson(id: 12, overallGrade: 93, durationMinutes: 90),
      reportJson(id: 11, overallGrade: 81, durationMinutes: 10),
      reportJson(id: 10, overallGrade: 72, reportDate: '2026-07-29T10:30:00'),
    ];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();

        expect(find.text('93%'), findsOneWidget);
        expect(find.text('A'), findsOneWidget);
        expect(
          find.text('Based on your 3 most recent saved trips (up to 100).'),
          findsOneWidget,
        );
        expect(find.text('Lifetime Stats'), findsNothing);
        await tester.scrollUntilVisible(find.byType(LineChart), 300);
        final chart = tester.widget<LineChart>(find.byType(LineChart));
        expect(chart.data.lineBarsData.first.spots.map((s) => s.y), [
          72,
          81,
          93,
        ]);

        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(12)),
          300,
        );
        final firstReport = tester.widget<ExpansionTile>(
          find.byType(ExpansionTile).first,
        );
        expect(firstReport.key, const PageStorageKey(12));
        expect(tester.takeException(), isNull);
      },
      () => MockClient(
        (_) async => http.Response(jsonEncode({'reports': reports}), 200),
      ),
    );
  });

  testWidgets('expands saved reports to show their own violation details', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(12)),
          300,
        );
        await tester.tap(find.byKey(const PageStorageKey(12)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Proper Speed'), 200);
        expect(find.textContaining('Roosevelt Blvd'), findsOneWidget);
        expect(find.textContaining('0 min 18 sec'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(11)),
          200,
        );
        await tester.tap(find.byKey(const PageStorageKey(11)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Smooth Braking'), 200);
        expect(find.textContaining('Road unavailable'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(10)),
          200,
        );
        await tester.tap(find.byKey(const PageStorageKey(10)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('No recorded violations for this trip.'),
          200,
        );
        expect(find.text('Date unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'reports': [
              reportJson(id: 12, violations: [violationJson()]),
              reportJson(
                id: 11,
                violations: [
                  violationJson(id: 4, type: 'Smooth Braking', roadName: null),
                ],
              ),
              reportJson(id: 10, reportDate: null),
            ],
          }),
          200,
        ),
      ),
    );
  });

  testWidgets('empty history can refresh and a failed refresh can retry', (
    tester,
  ) async {
    var requests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        expect(
          find.text('No trips yet. Finish a drive to see your stats here.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Refresh trip history'));
        await tester.pumpAndSettle();
        expect(
          find.text('Failed to load trip history. Please try again.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Last Drive'), findsOneWidget);
        expect(requests, 3);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        expect(request.url.queryParameters['limit'], '100');
        requests++;
        return switch (requests) {
          1 => http.Response('{"reports": []}', 200),
          2 => http.Response('{}', 500),
          _ => http.Response(
            jsonEncode({
              'reports': [reportJson()],
            }),
            200,
          ),
        };
      }),
    );
  });
}
