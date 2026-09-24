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

  testWidgets(
    'dashboard labels inferred limits and uses the server tolerance',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await http.runWithClient(
        () => onDashboard(tester, () async {
          expect(find.text('Unavailable'), findsOneWidget);
          expect(find.textContaining('Speed grading paused'), findsOneWidget);
          await drive(tester, 39, 12);
          expect(find.text('Estimated Limit'), findsOneWidget);
          expect(find.text('Nearest Road'), findsOneWidget);
          expect(find.text('Estimated from road type'), findsOneWidget);
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
          expect(tester.takeException(), isNull);
        }),
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'speedLimitMph': 25,
              'speedLimitSource': 'inferred',
              'speedingThresholdMph': 15,
              'roadName': 'Nearest Road',
              'distanceMeters': 3,
            }),
            200,
          ),
        ),
      );
    },
  );
}
