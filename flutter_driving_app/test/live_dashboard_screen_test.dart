// Simulated-drive testing estimated-limit labels, warning colors, grading,
// and narrow-screen layouts.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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
      await tester.pumpWidget(const MaterialApp(home: LiveDashboardScreen()));
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
    final card = find.ancestor(
      of: find.text('Proper Speed'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: card, matching: find.text(grade)),
      findsOneWidget,
    );
  }

  void expectSpeedColor(WidgetTester tester, double speed, Color? color) {
    final speedText = find.text('${speed.toStringAsFixed(0)} MPH').first;
    final normalColor = Theme.of(
      tester.element(speedText),
    ).textTheme.titleLarge!.color;
    expect(tester.widget<Text>(speedText).style!.color, color ?? normalColor);
  }

  testWidgets(
    'dashboard colors estimated ranges and groups speeding after a lookup timeout',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
          expect(find.text('Unavailable'), findsOneWidget);
          expect(find.textContaining('±'), findsNothing);
          expect(find.textContaining('Speed grading paused'), findsOneWidget);
          await drive(tester, 39, 12);
          expect(find.text('Estimated Limit'), findsOneWidget);
          expect(find.text('25±10 MPH'), findsOneWidget);
          expect(find.textContaining('Estimated range:'), findsNothing);
          expect(find.text('Nearest Road'), findsOneWidget);
          expectSpeedGrade('100');
          expect(
            tester.widget<Text>(find.text('39 MPH')).style!.color,
            Colors.orange,
          );

          await drive(tester, 40, 11);
          expectSpeedGrade('95');
          expect(
            tester.widget<Text>(find.text('40 MPH')).style!.color,
            Colors.red,
          );
          await drive(tester, 25, 1);
          expect(find.text('1 time speeding'), findsOneWidget);

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
              expect(find.text('25 MPH'), findsNWidgets(2));
            } else {
              expect(find.text('25±${scenario.range} MPH'), findsOneWidget);
            }
            expect(
              find.text(
                source == 'inferred' ? 'Estimated Limit' : 'Speed Limit',
              ),
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
          expect(find.text('Unavailable'), findsOneWidget);
          expect(find.textContaining('±'), findsNothing);
          expect(find.textContaining('Speed grading paused'), findsOneWidget);
          expectSpeedGrade('87');
          expectSpeedColor(tester, 30, null);

          // The late response must not unpause grading; a fresh lookup must
          delayedResponse.complete(limitResponse());
          await tester.pump();
          expect(find.text('Unavailable'), findsOneWidget);
          await drive(tester, 30, 3);
          expectSpeedGrade('87');
          expect(find.textContaining('2 times speeding'), findsOneWidget);

          // Grading resumes after the next lookup, and only the five seconds
          // after fresh grace are charged during the resumed streak.
          await drive(tester, 30, 12);
          expect(find.text('Speed Limit'), findsOneWidget);
          expect(find.textContaining('±'), findsNothing);
          expect(find.textContaining('Speed grading paused'), findsNothing);
          expectSpeedGrade('82');
          await drive(tester, 25, 1);
          expect(find.text('2 times speeding'), findsOneWidget);
          expect(find.text('3 times speeding'), findsNothing);
          expectSpeedGrade('82');
          expect(tester.takeException(), isNull);
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
