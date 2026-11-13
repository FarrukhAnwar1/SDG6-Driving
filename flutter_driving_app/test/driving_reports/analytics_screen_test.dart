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

  testWidgets(
    'mode badges default to all selected and support empty selection',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          for (final label in ['Regular', 'Navigation', 'Pocket']) {
            expect(
              tester
                  .widget<FilterChip>(find.widgetWithText(FilterChip, label))
                  .selected,
              isTrue,
            );
          }
          expect(find.text('Showing 3 matching trips.'), findsOneWidget);
          for (final (label, remaining) in [
            ('Regular', 2),
            ('Navigation', 1),
            ('Pocket', 0),
          ]) {
            await tester.tap(find.widgetWithText(FilterChip, label));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<FilterChip>(find.widgetWithText(FilterChip, label))
                  .selected,
              isFalse,
            );
            expect(
              find.text(
                'Showing $remaining matching trip${remaining == 1 ? '' : 's'}.',
              ),
              findsOneWidget,
            );
          }
          await tester.scrollUntilVisible(
            find.textContaining('No trips match these filters'),
            150,
          );
          await _scrollToTop(tester);
          await tester.tap(find.widgetWithText(FilterChip, 'Pocket'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 1 matching trip.'), findsOneWidget);
          expect(requests, 2); // Initial history and suggestions only.
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
                _modeReport(id: 3, mode: 'pocket', grade: 90),
                _modeReport(id: 2, mode: 'navigation', grade: 80),
                _modeReport(id: 1, mode: 'regular', grade: 70),
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  testWidgets('mode and time filters apply before the recent-trip limit', (
    tester,
  ) async {
    var historyRequests = 0;
    var suggestionRequests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '10'));
        await tester.pumpAndSettle();
        for (final label in ['Navigation', 'Pocket']) {
          await tester.tap(find.widgetWithText(FilterChip, label));
          await tester.pumpAndSettle();
        }
        // Twelve regular trips exist, including older ones outside the latest
        // ten trips across all modes. Keep the latest ten matching trips.
        expect(find.text('Showing 10 matching trips.'), findsOneWidget);
        await tester.ensureVisible(find.text('AM'));
        await tester.tap(find.text('AM'));
        await tester.pumpAndSettle();
        expect(find.text('Showing 6 matching trips.'), findsOneWidget);

        // Last drive, averages, chart and report list use the same selection.
        await tester.scrollUntilVisible(find.text('74%').first, 150);
        expect(find.text('74%'), findsWidgets);
        await tester.scrollUntilVisible(find.text('Total Trips'), 150);
        expect(find.text('6'), findsOneWidget);
        expect(find.text('74.4 mi'), findsOneWidget);
        expect(find.text('59%'), findsOneWidget);
        await tester.scrollUntilVisible(find.byType(LineChart), 250);
        expect(
          tester
              .widget<LineChart>(find.byType(LineChart))
              .data
              .lineBarsData
              .single
              .spots
              .map((spot) => spot.y),
          [44, 50, 56, 62, 68, 74],
        );
        await tester.scrollUntilVisible(
          find.byKey(const PageStorageKey(34)),
          250,
        );
        expect(
          tester.widget<ExpansionTile>(find.byType(ExpansionTile).first).key,
          const PageStorageKey(34),
        );
        expect(historyRequests, 1);
        expect(
          suggestionRequests,
          1,
        ); // Initial load only, independent of filters.
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        if (request.url.path == '/advanced-suggestion') {
          suggestionRequests++;
          return http.Response('{"message":"Keep recording your trips."}', 200);
        }
        historyRequests++;
        return http.Response(
          jsonEncode({
            'reports': [
              for (var id = 36; id > 0; id--)
                _modeReport(
                    id: id,
                    mode: ['regular', 'navigation', 'pocket'][(id - 1) % 3],
                    grade: 40.0 + id,
                  )
                  ..['reportDate'] = DateTime(2026, 7, 1)
                      .add(Duration(days: id, hours: id.isEven ? 9 : 15))
                      .toUtc()
                      .toIso8601String(),
            ],
          }),
          200,
        );
      }),
    );
  });

  testWidgets(
    'clear filters restores every default without refreshing advice',
    (tester) async {
      var historyRequests = 0;
      var suggestionRequests = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          final clear = find.widgetWithText(TextButton, 'Clear filters');
          expect(tester.widget<TextButton>(clear).onPressed, isNull);
          expect(find.text('Showing 30 matching trips.'), findsOneWidget);

          await tester.tap(find.widgetWithText(ChoiceChip, '10'));
          await tester.pumpAndSettle();
          for (final label in ['Regular', 'Navigation', 'Pocket']) {
            await tester.tap(find.widgetWithText(FilterChip, label));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.text('AM'));
          await tester.tap(find.text('AM'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Date range'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Switch to input'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(0), '07/10/2026');
          await tester.enterText(find.byType(TextField).at(1), '07/20/2026');
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(find.text('Showing 0 matching trips.'), findsOneWidget);
          expect(find.byTooltip('Clear date range'), findsOneWidget);

          await _scrollToTop(tester);
          expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
          await tester.tap(clear);
          await tester.pumpAndSettle();
          expect(tester.widget<TextButton>(clear).onPressed, isNull);
          expect(
            tester
                .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '100'))
                .selected,
            isTrue,
          );
          for (final label in ['Regular', 'Navigation', 'Pocket']) {
            expect(
              tester
                  .widget<FilterChip>(find.widgetWithText(FilterChip, label))
                  .selected,
              isTrue,
            );
          }
          expect(
            tester
                .widget<SegmentedButton<AnalyticsTimeOfDay>>(
                  find.byType(SegmentedButton<AnalyticsTimeOfDay>),
                )
                .selected,
            {AnalyticsTimeOfDay.all},
          );
          expect(find.text('Date range'), findsOneWidget);
          expect(find.byTooltip('Clear date range'), findsNothing);
          expect(find.text('Showing 30 matching trips.'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('Original advice'), 200);
          expect(historyRequests, 1);
          expect(suggestionRequests, 1);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path == '/advanced-suggestion') {
            suggestionRequests++;
            return http.Response('{"message":"Original advice"}', 200);
          }
          historyRequests++;
          return http.Response(
            jsonEncode({
              'reports': [
                for (var id = 30; id > 0; id--)
                  _modeReport(
                      id: id,
                      mode: ['regular', 'navigation', 'pocket'][(id - 1) % 3],
                      grade: 90,
                    )
                    ..['reportDate'] = DateTime(
                      2026,
                      7,
                      id,
                      id.isEven ? 9 : 15,
                    ).toUtc().toIso8601String(),
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  for (final mode in ['regular', 'navigation', 'pocket']) {
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
    'recent count filters cached history without refreshing suggestions',
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
            find.text('Advice for 100 trips'),
            300,
          );
          expect(
            find.text(
              'Based on up to 100 latest saved trips, across all driving modes, dates and times.',
            ),
            findsOneWidget,
          );
          expect(historyRequests, 1);
          expect(suggestionLimits, ['100']);
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
          // controls needed to recover. Suggestions stay independent of filters.
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
    var suggestionRequests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(ChoiceChip, '25'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(suggestionRequests, 1); // Keep the initial request in flight.
        await tester.tap(find.byTooltip('Refresh trip history'));
        await tester.pumpAndSettle();
        expect(suggestionRequests, 2);
        oldResponse.complete(http.Response('{"message":"Old advice"}', 200));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('New advice'), 300);
        expect(find.text('Old advice'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        if (request.url.path == '/advanced-suggestion') {
          expect(request.url.queryParameters['limit'], '100');
          suggestionRequests++;
          if (suggestionRequests == 1) {
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
  testWidgets('Pocket reports show their badge and Not Tracked rows', (
    tester,
  ) async {
    final report = reportJson(
      id: 1,
      drivingMode: 'pocket',
      focusGrade: null,
      followingDistanceGrade: null,
    );
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Last Drive'), 150);
        // One row for focus and one for following distance
        expect(find.text('Not Tracked'), findsNWidgets(2));
        await tester.scrollUntilVisible(find.text('Pocket Mode'), 300);
        expect(find.text('Pocket Mode'), findsOneWidget);
        expect(find.text('Regular Mode'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      () => _analyticsClient(
        (_) async => http.Response(
          jsonEncode({
            'reports': [report],
          }),
          200,
        ),
      ),
    );
  });

  testWidgets(
    'Following distance chart skips untracked trips and keeps zero scores',
    (tester) async {
      final reports = [
        reportJson(id: 3, followingDistanceGrade: 0),
        reportJson(
          id: 2,
          drivingMode: 'pocket',
          focusGrade: null,
          followingDistanceGrade: null,
        ),
        reportJson(id: 1, followingDistanceGrade: 80),
      ];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byType(DropdownButtonFormField<String>),
            300,
          );
          await tester.ensureVisible(
            find.byType(DropdownButtonFormField<String>),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Following Distance').last);
          await tester.pumpAndSettle();

          final spots = tester
              .widget<LineChart>(find.byType(LineChart))
              .data
              .lineBarsData
              .single
              .spots;
          expect(spots.map((spot) => spot.isNull()), [false, true, false]);
          expect(spots.first.y, 80);
          // A real score of zero is plotted, not treated as missing
          expect(spots.last.y, 0);
          expect(
            find.text(
              '1 of 3 trips did not track this grade and appear as gaps.',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
        () => _analyticsClient(
          (_) async => http.Response(jsonEncode({'reports': reports}), 200),
        ),
      );
    },
  );

  testWidgets('Following distance chart says when no trip tracked it', (
    tester,
  ) async {
    final reports = [
      for (final id in [2, 1])
        reportJson(
          id: id,
          drivingMode: 'pocket',
          focusGrade: null,
          followingDistanceGrade: null,
        ),
    ];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(DropdownButtonFormField<String>),
          300,
        );
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Following Distance').last);
        await tester.pumpAndSettle();
        expect(find.byType(LineChart), findsNothing);
        expect(
          find.text('This grade was not tracked in the selected trips.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      () => _analyticsClient(
        (_) async => http.Response(jsonEncode({'reports': reports}), 200),
      ),
    );
  });

  testWidgets('driving totals include regular, navigation and pocket trips', (
    tester,
  ) async {
    final reports = [
      _modeReport(id: 3, mode: 'pocket', grade: 90),
      _modeReport(id: 2, mode: 'navigation', grade: 90),
      _modeReport(id: 1, mode: 'regular', grade: 90),
    ];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: AnalyticsScreen()));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Total Trips'), 200);
        expect(find.text('3'), findsOneWidget);
        // reportJson uses 12.4 miles per trip
        expect(find.text('37.2 mi'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      () => _analyticsClient(
        (_) async => http.Response(jsonEncode({'reports': reports}), 200),
      ),
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
    'focusGrade': mode == 'regular' ? grade : null,
    'followingDistanceGrade': mode == 'pocket' ? null : grade,
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
