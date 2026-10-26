// Widget Tests for the Home Screen
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/screens/home_screen.dart';
import 'package:flutter_driving_app/screens/live_dashboard_screen.dart';
import 'package:flutter_driving_app/widgets/driving/background_location_service.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sensors_plus/sensors_plus.dart';

class _Locations extends GeolocatorPlatform {
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      const Stream.empty();
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
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const loadError = 'Could not load your driving mode. Please try again.';
  late bool failModeReads;
  late int modeReads;
  Completer<void>? pendingModeRead;
  late GeolocatorPlatform originalLocations;
  late SensorsPlatform originalSensors;

  setUp(() {
    failModeReads = true;
    modeReads = 0;
    pendingModeRead = null;
    originalLocations = GeolocatorPlatform.instance;
    originalSensors = SensorsPlatform.instance;
    GeolocatorPlatform.instance = _Locations();
    SensorsPlatform.instance = _Sensors();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storageChannel, (
      call,
    ) async {
      expect(call.method, 'read');
      final key = (call.arguments as Map)['key'];
      if (key == 'access_token') return 'test-token';
      expect(key, 'driving_mode');
      modeReads++;
      await pendingModeRead?.future;
      if (failModeReads) throw PlatformException(code: 'read_failed');
      return 'navigation';
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storageChannel,
      null,
    );
    GeolocatorPlatform.instance = originalLocations;
    SensorsPlatform.instance = originalSensors;
  });

  testWidgets(
    'Start Trip handles a mode read failure and retries the saved mode',
    (tester) async {
      try {
        await http.runWithClient(
          () async {
            await tester.pumpWidget(const MaterialApp(home: HomePage()));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Start Trip'));
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.byType(LiveDashboardScreen), findsNothing);
            expect(find.text(loadError), findsOneWidget);
            expect(modeReads, 1);

            failModeReads = false;
            pendingModeRead = Completer<void>();
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            final startButton = find.widgetWithText(FilledButton, 'Start Trip');
            expect(tester.widget<FilledButton>(startButton).onPressed, isNull);
            await tester.tap(startButton);
            await tester.pump();
            expect(modeReads, 2);
            expect(find.byType(LiveDashboardScreen), findsNothing);

            pendingModeRead!.complete();
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LiveDashboardScreen>(find.byType(LiveDashboardScreen))
                  .drivingMode,
              DrivingMode.navigation,
            );
            expect(find.text(loadError), findsNothing);
            expect(modeReads, 2);
            expect(tester.takeException(), isNull);
          },
          () => MockClient((request) async {
            expect(request.url.path, '/me');
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'Alex',
                'email': 'alex@example.com',
              }),
              200,
            );
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(BackgroundLocationService.stop);
      }
    },
  );
}
