// Simulated-drive testing estimated-limit labels, warning colors, grading,
// and narrow-screen layouts.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_driving_app/screens/live_dashboard_screen.dart';
import 'package:flutter_driving_app/widgets/background_location_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sensors_plus/sensors_plus.dart';

class _Locations extends GeolocatorPlatform {
  final positions = StreamController<Position>.broadcast();
  DateTime timestamp = DateTime(2026, 9, 18, 10);
  double latitude = 40;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;

  void drive(double speedMph) {
    final metersPerSecond = speedMph / 2.23694;
    timestamp = timestamp.add(const Duration(seconds: 1));
    latitude += metersPerSecond / 111195;
    positions.add(
      Position(
        latitude: latitude,
        longitude: -75,
        timestamp: timestamp,
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: metersPerSecond,
        speedAccuracy: 0.1,
      ),
    );
  }
}

class _Sensors extends SensorsPlatform {
  @override
  Stream<AccelerometerEvent> accelerometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) => const Stream.empty();

  @override
  Stream<UserAccelerometerEvent> userAccelerometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) => const Stream.empty();

  @override
  Stream<GyroscopeEvent> gyroscopeEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Locations locations;
  late GeolocatorPlatform originalLocation;
  late SensorsPlatform originalSensors;

  setUp(() {
    originalLocation = GeolocatorPlatform.instance;
    originalSensors = SensorsPlatform.instance;
    locations = _Locations();
    GeolocatorPlatform.instance = locations;
    SensorsPlatform.instance = _Sensors();
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  tearDown(() {
    GeolocatorPlatform.instance = originalLocation;
    SensorsPlatform.instance = originalSensors;
  });

  Future<void> onDashboard(
    WidgetTester tester,
    Future<void> Function() check,
  ) async {
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
          home: const LiveDashboardScreen(),
        ),
      );
      await tester.pump();
      await check();
    } finally {
      // Drain the location service's queue while still in the widget-test zone
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        await BackgroundLocationService.stop();
        await locations.positions.close();
      });
    }
  }

  Future<void> drive(WidgetTester tester, double speed, int samples) async {
    for (var i = 0; i < samples; i++) {
      locations.drive(speed);
      await tester.pump();
      await tester.pump();
    }
  }

  void expectSpeedGrade(String grade) {
    final row = find.byKey(const ValueKey('grade-Proper Speed'));
    expect(
      find.descendant(of: row, matching: find.text(grade)),
      findsOneWidget,
    );
  }

  void expectSpeedColor(WidgetTester tester, double speed, Color? color) {
    final speedText = find.byKey(const ValueKey('current-speed'));
    expect(tester.widget<Text>(speedText).data, speed.toStringAsFixed(0));
    final normalColor = Theme.of(
      tester.element(speedText),
    ).textTheme.displayLarge!.color;
    expect(tester.widget<Text>(speedText).style!.color, color ?? normalColor);
  }

  void expectLimit(WidgetTester tester, String value, {String? range}) {
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('speed-limit-value'))).data,
      value,
    );
    final rangeFinder = find.byKey(const ValueKey('speed-limit-range'));
    if (range == null) {
      expect(rangeFinder, findsNothing);
    } else {
      expect(tester.widget<Text>(rangeFinder).data, '±$range');
    }
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
  }

  void expectDashboardFits(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsNothing);
    final stop = find.byKey(const ValueKey('stop-trip'));
    expect(stop.hitTestable(), findsOneWidget);
    final stopBounds = tester.getRect(stop);
    final screenHeight = tester.view.physicalSize.height;
    expect(stopBounds.bottom, lessThanOrEqualTo(screenHeight - 24));

    final limit = find.byKey(const ValueKey('speed-limit-value'));
    final limitText = tester.widget<Text>(limit).data!;
    final limitParagraph = tester.renderObject<RenderParagraph>(limit);
    final limitLines = limitParagraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: limitText.length),
    );
    expect(limitLines, hasLength(1));

    for (final label in [
      'Proper Speed',
      'Focused Driving',
      'Smooth Braking',
      'Smooth Accelerating',
      'Smooth Turning',
    ]) {
      final row = find.byKey(ValueKey('grade-$label'));
      final bar = find.descendant(
        of: row,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(find.text(label).hitTestable(), findsOneWidget);
      expect(bar.hitTestable(), findsOneWidget);
      expect(tester.getRect(row).top, greaterThan(80));
      expect(tester.getRect(row).bottom, lessThan(stopBounds.top));
      expect(tester.getRect(bar).bottom, lessThan(stopBounds.top));
    }

    final tripCard = find.ancestor(
      of: find.text('TIME'),
      matching: find.byType(Card),
    );
    final rightEdge = tester.getRect(tripCard).right - 20;
    for (final label in ['TIME', 'MILES']) {
      for (final part in ['label', 'value']) {
        final stat = find.byKey(ValueKey('stat-$label-$part'));
        expect(stat.hitTestable(), findsOneWidget);
        expect(tester.getRect(stat).right, closeTo(rightEdge, 0.1));
      }
    }
  }

  Future<void> expectResponsiveLayout(WidgetTester tester) async {
    // Resize the same live trip, keeping its GPS stream and grades active
    for (final viewport in [
      (size: const Size(320, 640), textScale: 1.0),
      (size: const Size(360, 800), textScale: 1.0),
      (size: const Size(411, 891), textScale: 1.0),
      (size: const Size(456, 1020), textScale: 1.0),
      (size: const Size(360, 800), textScale: 1.5),
    ]) {
      tester.view.physicalSize = viewport.size;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
      await tester.pump();
      expectDashboardFits(tester);
    }
    tester.view.physicalSize = const Size(360, 800);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump();
  }

  testWidgets(
    'dashboard colors estimated ranges and groups speeding after a lookup timeout',
    (tester) async {
      setViewport(tester, const Size(360, 800));
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      double threshold = 15;
      var source = 'inferred';
      var delayNextLookup = false;
      final delayedResponse = Completer<http.Response>();
      http.Response limitResponse() => http.Response(
        jsonEncode({
          'speedLimitMph': 25,
          'speedLimitSource': source,
          'speedingThresholdMph': threshold,
          'roadName': 'Nearest Road',
          'distanceMeters': 3,
        }),
        200,
      );

      // Follow one trip through changing road metadata, a real two-second
      // request timeout, and recovery on the same road.
      await http.runWithClient(
        () => onDashboard(tester, () async {
          expectLimit(tester, '--');
          expect(find.textContaining('±'), findsNothing);
          expect(find.text('Forward G'), findsNothing);
          expect(find.text('Lateral G'), findsNothing);
          expect(
            find.textContaining(RegExp(r'\d+ (times?|events?)')),
            findsNothing,
          );
          await expectResponsiveLayout(tester);
          await drive(tester, 39, 12);
          expect(find.text('EST.\nLIMIT'), findsOneWidget);
          expectLimit(tester, '25', range: '10');
          expect(find.textContaining('Estimated range:'), findsNothing);
          expect(find.text('Nearest Road'), findsOneWidget);
          expectSpeedGrade('100');
          expectSpeedColor(tester, 39, Colors.orange);
          await expectResponsiveLayout(tester);

          await drive(tester, 40, 11);
          expectSpeedGrade('95');
          expectSpeedColor(tester, 40, Colors.red);
          await drive(tester, 25, 1);
          expect(find.textContaining('time speeding'), findsNothing);

          for (final scenario in [
            (source: 'posted', threshold: 5.0, range: null),
            (source: 'inferred', threshold: 10.0, range: '5'),
            (source: 'inferred', threshold: 7.5, range: '2.5'),
            (source: 'inferred', threshold: 5.0, range: null),
            (source: 'inferred', threshold: 2.5, range: null),
            (source: 'posted', threshold: 5.0, range: null),
          ]) {
            source = scenario.source;
            threshold = scenario.threshold;
            await drive(tester, 25, 4);
            if (scenario.range == null) {
              expect(find.textContaining('±'), findsNothing);
              expectLimit(tester, '25');
            } else {
              expectLimit(tester, '25', range: scenario.range);
            }
            expect(
              find.text(source == 'inferred' ? 'EST.\nLIMIT' : 'SPEED\nLIMIT'),
              findsOneWidget,
            );
            expectSpeedGrade('95');

            final range = double.tryParse(scenario.range ?? '') ?? 0;
            final upperLimit = 25 + range;
            final speedingAt = 25 + threshold;
            final bufferSpeed = (upperLimit + speedingAt) / 2;

            // The upper edge stays neutral; only the buffer above it warns
            await drive(tester, upperLimit, 1);
            expectSpeedColor(tester, upperLimit, null);
            await drive(tester, bufferSpeed, 1);
            expectSpeedColor(tester, bufferSpeed, Colors.orange);
            await drive(tester, speedingAt, 1);
            expectSpeedColor(tester, speedingAt, Colors.red);
            await drive(tester, 25, 1);
            expectSpeedColor(tester, 25, null);
            expectSpeedGrade('95');
          }

          // A second sustained episode, well outside the first one's window
          await drive(tester, 30, 12);
          expectSpeedGrade('89');
          delayNextLookup = true;
          await drive(tester, 30, 2);
          await tester.pump(const Duration(seconds: 2));
          expectLimit(tester, '--');
          expect(find.textContaining('±'), findsNothing);
          expectSpeedGrade('87');
          expectSpeedColor(tester, 30, null);

          // The late response must not unpause grading; a fresh lookup must
          delayedResponse.complete(limitResponse());
          await tester.pump();
          expectLimit(tester, '--');
          await drive(tester, 30, 3);
          expectSpeedGrade('87');
          expect(find.textContaining('times speeding'), findsNothing);

          // Grading resumes after the next lookup, and only the five seconds
          // after fresh grace are charged during the resumed streak.
          await drive(tester, 30, 12);
          expect(find.text('SPEED\nLIMIT'), findsOneWidget);
          expect(find.textContaining('±'), findsNothing);
          expectSpeedGrade('82');
          await drive(tester, 25, 1);
          expect(
            find.textContaining(RegExp(r'\d+ (times?|events?)')),
            findsNothing,
          );
          expectSpeedGrade('82');
          expectDashboardFits(tester);
        }),
        () => MockClient((_) async {
          if (delayNextLookup) {
            delayNextLookup = false;
            return delayedResponse.future;
          }
          return limitResponse();
        }),
      );
    },
  );
}
