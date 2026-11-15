// Verifies app-wide theme updates from preferences and the existing GPS feed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_driving_app/main.dart';
import 'package:flutter_driving_app/screens/login_screen.dart';
import 'package:flutter_driving_app/widgets/driving/background_location_service.dart';
import 'package:flutter_driving_app/widgets/theme/theme_settings.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class _Locations extends GeolocatorPlatform {
  final positions = StreamController<Position>.broadcast();

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => null;

  void emit(double longitude) {
    positions.add(
      Position(
        latitude: 0,
        longitude: longitude,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app follows existing GPS updates in auto mode and preserves navigation',
    (tester) async {
      final original = GeolocatorPlatform.instance;
      final locations = _Locations();
      GeolocatorPlatform.instance = locations;
      FlutterSecureStorage.setMockInitialValues({});
      await themeSettings.load();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await BackgroundLocationService.stop();
        await locations.positions.close();
        GeolocatorPlatform.instance = original;
      });

      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      Brightness brightness() =>
          Theme.of(tester.element(find.byType(LoginPage))).brightness;
      expect(brightness(), Brightness.dark);
      expect(BackgroundLocationService.isTracking, isFalse);

      // A manual change must keep the navigator and current form state alive.
      final email = find.byType(TextFormField).first;
      await tester.enterText(email, 'driver@example.com');
      await themeSettings.setDark(false);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      expect(find.text('driver@example.com'), findsOneWidget);

      await themeSettings.setAutoSwitch(true);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
      expect(BackgroundLocationService.isTracking, isFalse);
      // Simulate tracking started by the existing permission/authentication flow.
      await BackgroundLocationService.start();
      final utc = DateTime.now().toUtc();
      final hours = utc.hour + utc.minute / 60;
      double normalize(double longitude) => (longitude + 180) % 360 - 180;
      final dayLongitude = normalize(180 - hours * 15);
      locations.emit(dayLongitude);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      locations.emit(normalize(dayLongitude + 180));
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
      expect(find.text('driver@example.com'), findsOneWidget);

      await themeSettings.setAutoSwitch(false);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      locations.emit(normalize(dayLongitude + 180));
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
