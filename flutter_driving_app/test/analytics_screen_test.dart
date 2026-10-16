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

  for (final scenario in [
    (count: 7, width: 440.0, textScale: 1.0, unknownDates: false),
    (count: 12, width: 320.0, textScale: 1.0, unknownDates: false),
    (count: 100, width: 320.0, textScale: 1.5, unknownDates: false),
    (count: 2, width: 320.0, textScale: 1.5, unknownDates: false),
    (count: 7, width: 800.0, textScale: 1.0, unknownDates: false),
    (count: 12, width: 320.0, textScale: 1.5, unknownDates: true),
  ]) {
    testWidgets('date labels stay apart for $scenario', (tester) async {
      await tester.binding.setSurfaceSize(Size(scenario.width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final firstDate = DateTime.utc(2026, 9, 27, 12);
      final reports = [
        for (var i = 0; i < scenario.count; i++)
          reportJson(
            id: i + 1,
            reportDate: scenario.unknownDates
                ? null
                : firstDate.add(Duration(days: i)).toIso8601String(),
          ),
      ];

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
                child: child!,
              ),
              home: const AnalyticsScreen(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.byType(LineChart), 300);
          await tester.pumpAndSettle();

          final titles = find.descendant(
            of: find.byType(LineChart),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SideTitleWidget &&
                  widget.meta.axisSide == AxisSide.bottom,
            ),
          );
          final labels = find.descendant(
            of: titles,
            matching: find.byType(Text),
          );
          final texts = tester.widgetList<Text>(labels).toList();
          expect(texts.length, greaterThanOrEqualTo(2));
          if (!scenario.unknownDates) {
            final firstLocalDate = firstDate.toLocal();
            final lastDate = firstDate
                .add(Duration(days: scenario.count - 1))
                .toLocal();
            expect(
              texts.first.data,
              '${firstLocalDate.month}/${firstLocalDate.day}',
            );
            expect(texts.last.data, '${lastDate.month}/${lastDate.day}');
            expect(texts.map((text) => text.data).toSet().length, texts.length);
          }

          final chartBounds = tester.getRect(find.byType(LineChart));
          Rect? previousBounds;
          for (final text in texts) {
            final bounds = tester.getRect(find.byWidget(text));
            expect(bounds.left, greaterThanOrEqualTo(chartBounds.left));
            expect(bounds.right, lessThanOrEqualTo(chartBounds.right));
            if (previousBounds != null) {
              expect(
                bounds.left - previousBounds.right,
                greaterThanOrEqualTo(8),
              );
            }
            previousBounds = bounds;
          }
          expect(tester.takeException(), isNull);
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({'reports': reports.reversed.toList()}),
            200,
          ),
        ),
      );
    });
  }

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
