// Widget tests for the AnalyticsScreen
import 'dart:async';
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/analytics_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fixtures/driving_report_fixtures.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  for (final mode in ['regular', 'navigation']) {
    final otherMode = mode == 'regular' ? 'navigation' : 'regular';

    testWidgets(
      'switching to $mode suppresses Overall comparison without same-mode history',
      (tester) async {
        Map<String, dynamic> trip(int id, String drivingMode) =>
            _modeReport(id: id, mode: drivingMode, grade: 100)..addAll({
              'overallGrade': drivingMode == 'regular' ? 80 : 100,
              'focusGrade': drivingMode == 'regular' ? 0 : null,
            });
        await http.runWithClient(
          () async {
            await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Last Drive'), 150);
            await tester.scrollUntilVisible(
              find.text(
                'Overall comparison needs an earlier trip in this driving mode.',
              ),
              150,
            );

            final overallRow = find
                .ancestor(
                  of: find.text('Overall').first,
                  matching: find.byType(Row),
                )
                .first;
            expect(
              find.descendant(
                of: overallRow,
                matching: find.textContaining('pts'),
              ),
              findsNothing,
            );
            final speedRow = find
                .ancestor(
                  of: find.text('Speed').first,
                  matching: find.byType(Row),
                )
                .first;
            expect(
              find.descendant(of: speedRow, matching: find.text('0 pts')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          },
          () => _analyticsClient(
            (_) async => http.Response(
              jsonEncode({
                'reports': [trip(2, mode), trip(1, otherMode)],
              }),
              200,
            ),
          ),
        );
      },
    );

    testWidgets('Overall uses only prior $mode trips in mixed history', (
      tester,
    ) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('Last Drive'), 150);
          await tester.scrollUntilVisible(
            find.text(
              'Overall is compared with your 2 prior trips in this driving mode.',
            ),
            150,
          );

          final overallRow = find
              .ancestor(
                of: find.text('Overall').first,
                matching: find.byType(Row),
              )
              .first;
          expect(
            find.descendant(of: overallRow, matching: find.text('20 pts')),
            findsOneWidget,
          );
          final speedRow = find
              .ancestor(
                of: find.text('Speed').first,
                matching: find.byType(Row),
              )
              .first;
          expect(
            find.descendant(of: speedRow, matching: find.text('47 pts')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
        () => _analyticsClient(
          (_) async => http.Response(
            jsonEncode({
              'reports': [
                _modeReport(id: 4, mode: mode, grade: 100),
                _modeReport(id: 3, mode: mode, grade: 90),
                _modeReport(id: 2, mode: otherMode, grade: 0),
                _modeReport(id: 1, mode: mode, grade: 70),
              ],
            }),
            200,
          ),
        ),
      );
    });
  }

  testWidgets(
    'recent count filters cached history and updates suggestion limit',
    (tester) async {
      var historyRequests = 0;
      final suggestionLimits = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '100'))
                .selected,
            isTrue,
          );
          expect(find.text('Showing 30 matching trips.'), findsOneWidget);
          await tester.scrollUntilVisible(find.byType(LineChart), 300);
          expect(
            tester
                .widget<LineChart>(find.byType(LineChart))
                .data
                .lineBarsData
                .first
                .spots
                .map((spot) => spot.y),
            [for (var id = 1; id <= 30; id++) 60 + id],
          );

          await _scrollToTop(tester);
          await tester.tap(find.widgetWithText(ChoiceChip, '25'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 25 matching trips.'), findsOneWidget);
          await tester.scrollUntilVisible(find.byType(LineChart), 300);
          expect(
            tester
                .widget<LineChart>(find.byType(LineChart))
                .data
                .lineBarsData
                .first
                .spots
                .map((spot) => spot.y),
            [for (var id = 6; id <= 30; id++) 60 + id],
          );
          await _scrollToTop(tester);
          await tester.scrollUntilVisible(
            find.text('Advice for 25 trips'),
            300,
          );
          expect(historyRequests, 1);
          expect(suggestionLimits, ['100', '25']);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer test-token');
          if (request.url.path == '/advanced-suggestion') {
            final limit = request.url.queryParameters['limit']!;
            suggestionLimits.add(limit);
            return http.Response(
              jsonEncode({'message': 'Advice for $limit trips'}),
              200,
            );
          }
          expect(request.url.path, '/driving-reports');
          expect(request.url.queryParameters, {'limit': '100'});
          historyRequests++;
          return http.Response(
            jsonEncode({
              'reports': [
                for (var id = 30; id > 0; id--)
                  reportJson(id: id, overallGrade: 60 + id),
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  testWidgets(
    'AM and PM use local time and update all analytics without requests',
    (tester) async {
      var historyRequests = 0;
      var suggestionRequests = 0;
      final localTimes = [
        DateTime(2026, 7, 30),
        DateTime(2026, 7, 30, 11, 59),
        DateTime(2026, 7, 30, 12),
        DateTime(2026, 7, 30, 23, 59),
      ];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          expect(find.text('Showing 5 matching trips.'), findsOneWidget);
          for (final period in ['AM', 'PM']) {
            await _scrollToTop(tester);
            await tester.tap(find.text(period));
            await tester.pumpAndSettle();
            expect(find.text('Showing 2 matching trips.'), findsOneWidget);
            // The last-drive grade, stats average, chart, and saved reports all
            // describe the same two matching reports.
            final lastGrade = period == 'AM' ? '70%' : '90%';
            final averageGrade = period == 'AM' ? '65%' : '85%';
            await tester.scrollUntilVisible(find.text('Last Drive'), 150);
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text(lastGrade).first, 150);
            expect(find.text(lastGrade), findsWidgets);
            await tester.scrollUntilVisible(find.text(averageGrade), 150);
            expect(find.text(averageGrade), findsOneWidget);
            await tester.scrollUntilVisible(find.byType(LineChart), 200);
            expect(
              tester
                  .widget<LineChart>(find.byType(LineChart))
                  .data
                  .lineBarsData
                  .first
                  .spots
                  .map((spot) => spot.y),
              period == 'AM' ? [60, 70] : [80, 90],
            );
            final newestId = period == 'AM' ? 2 : 4;
            await tester.scrollUntilVisible(
              find.byKey(PageStorageKey(newestId)),
              200,
            );
            expect(
              tester
                  .widget<ExpansionTile>(find.byType(ExpansionTile).first)
                  .key,
              PageStorageKey(newestId),
            );
          }
          await _scrollToTop(tester);
          await tester.tap(find.text('All day'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 5 matching trips.'), findsOneWidget);
          expect(historyRequests, 1);
          expect(suggestionRequests, 1);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path == '/advanced-suggestion') {
            suggestionRequests++;
            return http.Response(
              '{"message":"Keep recording your trips."}',
              200,
            );
          }
          historyRequests++;
          return http.Response(
            jsonEncode({
              'reports': [
                for (var index = 3; index >= 0; index--)
                  reportJson(
                    id: index + 1,
                    overallGrade: 60 + index * 10,
                    reportDate: localTimes[index].toUtc().toIso8601String(),
                  ),
                reportJson(id: 0, reportDate: null),
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  testWidgets(
    'date range includes both full days and can clear an empty result',
    (tester) async {
      var requests = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Date range'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Switch to input'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(0), '07/30/2026');
          await tester.enterText(find.byType(TextField).at(1), '07/31/2026');
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 2 matching trips.'), findsOneWidget);
          await tester.scrollUntilVisible(find.byType(LineChart), 300);
          expect(
            tester
                .widget<LineChart>(find.byType(LineChart))
                .data
                .lineBarsData
                .first
                .spots
                .map((spot) => spot.y),
            [70, 80],
          );

          // Combine filters, then choose an empty date range without losing the
          // controls needed to recover. Suggestions continue to use recent count.
          await _scrollToTop(tester);
          await tester.tap(find.text('AM'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 1 matching trip.'), findsOneWidget);
          await tester.tap(find.byIcon(Icons.date_range));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Switch to input'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(0), '08/01/2026');
          await tester.enterText(find.byType(TextField).at(1), '08/01/2026');
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 0 matching trips.'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.textContaining('No trips match these filters'),
            150,
          );
          expect(
            find.textContaining('No trips match these filters'),
            findsOneWidget,
          );
          await _scrollToTop(tester);
          await tester.tap(find.byTooltip('Clear date range'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 2 matching trips.'), findsOneWidget);
          await tester.tap(find.text('All day'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 4 matching trips.'), findsOneWidget);
          expect(requests, 2); // One history request and one suggestion request
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          requests++;
          if (request.url.path == '/advanced-suggestion') {
            return http.Response(
              '{"message":"Keep recording your trips."}',
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'reports': [
                reportJson(
                  id: 3,
                  reportDate: DateTime(2026, 8, 2).toUtc().toIso8601String(),
                ),
                reportJson(
                  id: 2,
                  overallGrade: 80,
                  reportDate: DateTime(
                    2026,
                    7,
                    31,
                    23,
                    59,
                    59,
                  ).toUtc().toIso8601String(),
                ),
                reportJson(
                  id: 1,
                  overallGrade: 70,
                  reportDate: DateTime(2026, 7, 30).toUtc().toIso8601String(),
                ),
                reportJson(id: 0, reportDate: null),
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  testWidgets('out of order suggestion responses cannot replace newer advice', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(ChoiceChip, '25'));
        await tester.pumpAndSettle();
        oldResponse.complete(http.Response('{"message":"Old advice"}', 200));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('New advice'), 300);
        expect(find.text('Old advice'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        if (request.url.path == '/advanced-suggestion') {
          if (request.url.queryParameters['limit'] == '100') {
            return oldResponse.future;
          }
          return http.Response('{"message":"New advice"}', 200);
        }
        return http.Response(
          jsonEncode({
            'reports': [reportJson()],
          }),
          200,
        );
      }),
    );
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

        expect(
          find.text('Based on your 3 most recent saved trips (up to 100).'),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(find.text('93%'), 200);
        expect(find.text('93%'), findsOneWidget);
        expect(find.text('A'), findsOneWidget);
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
      () => _analyticsClient(
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
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const PageStorageKey(12)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Proper Speed'), 200);
        expect(find.textContaining('Roosevelt Blvd'), findsOneWidget);
        expect(find.textContaining('0 min 18 sec'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(11)),
          200,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const PageStorageKey(11)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Smooth Braking'), 200);
        expect(find.textContaining('Road unavailable'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(10)),
          200,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const PageStorageKey(10)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('No recorded violations for this trip.'),
          200,
        );
        expect(find.text('Date unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      () => _analyticsClient(
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
          await tester.tap(find.widgetWithText(ChoiceChip, '100'));
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
        () => _analyticsClient(
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
        await tester.scrollUntilVisible(find.text('Last Drive'), 200);
        expect(find.text('Last Drive'), findsOneWidget);
        expect(requests, 3);
        expect(tester.takeException(), isNull);
      },
      () => _analyticsClient((request) async {
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

Map<String, dynamic> _modeReport({
  required int id,
  required String mode,
  required double grade,
}) => reportJson(id: id, overallGrade: grade)
  ..addAll({
    'drivingMode': mode,
    'speedGrade': grade,
    'brakingGrade': grade,
    'accelerationGrade': grade,
    'turningGrade': grade,
    'focusGrade': mode == 'navigation' ? null : grade,
  });

MockClient _analyticsClient(
  Future<http.Response> Function(http.Request) historyHandler,
) => MockClient((request) async {
  if (request.url.path == '/advanced-suggestion') {
    return http.Response(
      '{"message":"Keep tracking your driving progress."}',
      200,
    );
  }
  return historyHandler(request);
});

Future<void> _scrollToTop(WidgetTester tester) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
}
