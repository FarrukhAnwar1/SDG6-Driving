// Simulated drives checking which Live Voice Feedback alerts the dashboard
// speaks, and when. Uses the same fake GPS/sensor/speed-limit setup as
// test/driving/live_dashboard_screen_test.dart, plus a fake speech output.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/live_dashboard_screen.dart';
import 'package:flutter_driving_app/screens/driving_report_screen.dart';
import 'package:flutter_driving_app/widgets/driving/background_location_service.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_alerts.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_output.dart';
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

// Records phrases; each one finishes immediately.
class _Speech implements VoiceOutput {
  final List<String> spoken = [];
  int stopCalls = 0;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Locations locations;
  late _Speech speech;
  late GeolocatorPlatform originalLocation;
  late SensorsPlatform originalSensors;

  setUp(() {
    originalLocation = GeolocatorPlatform.instance;
    originalSensors = SensorsPlatform.instance;
    locations = _Locations();
    speech = _Speech();
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
    Future<void> Function() check, {
    required DrivingMode mode,
    required double speedLimitMph,
    FollowingDistanceCameraBuilder? cameraBuilder,
    bool voiceFeedbackEnabled = true,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await http.runWithClient(
      () async {
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: LiveDashboardScreen(
                drivingMode: mode,
                clock: () => locations.timestamp,
                followingDistanceCameraBuilder:
                    cameraBuilder ?? (_, _, _) => const SizedBox(),
                voiceFeedbackEnabled: voiceFeedbackEnabled,
                voiceOutput: speech,
              ),
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
      },
      () => MockClient(
        (_) async => http.Response(
          '{"speedLimitMph":$speedLimitMph,"speedLimitSource":"posted",'
          '"speedingThresholdMph":5}',
          200,
        ),
      ),
    );
  }

  Future<void> drive(WidgetTester tester, double speed, int samples) async {
    for (var i = 0; i < samples; i++) {
      locations.drive(speed);
      await tester.pump();
      await tester.pump();
    }
  }

  // The displayed Proper Speed grade (the row's label is its first Text)
  String gradeText(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('grade-Proper Speed')),
          matching: find.byType(Text),
        ),
      )
      .last
      .data!;

  Future<void> stopTrip(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('stop-trip')));
    await tester.pumpAndSettle();
    expect(find.byType(DrivingReportScreen), findsOneWidget);
  }

  testWidgets(
    'Pocket sustained speeding gives one alert, only once points come off',
    (tester) async {
      await onDashboard(
        tester,
        () async {
          var fixes = 0;
          while (speech.spoken.isEmpty && fixes < 20) {
            final gradeBefore = gradeText(tester);
            await drive(tester, 30, 1);
            fixes++;
            if (speech.spoken.isEmpty) {
              expect(gradeText(tester), '100', reason: 'fix $fixes');
            } else {
              // Spoken on the very fix that first cost points
              expect(gradeBefore, '100');
              expect(gradeText(tester), '99');
            }
          }
          expect(speech.spoken, [VoiceAlert.speeding.phrase]);
          // Grace (5 s) plus the cached first fix and the first limit lookup
          expect(fixes, greaterThan(6));

          await drive(tester, 30, 20);
          expect(speech.spoken, [VoiceAlert.speeding.phrase]);
          await stopTrip(tester);
          expect(speech.stopCalls, 1);
          expect(speech.spoken, [VoiceAlert.speeding.phrase]);
          expect(tester.takeException(), isNull);
        },
        mode: DrivingMode.pocket,
        speedLimitMph: 25,
      );
    },
  );

  for (final mode in [DrivingMode.normal, DrivingMode.navigation]) {
    testWidgets(
      '${mode.apiValue} following too closely gives one following alert',
      (tester) async {
        ValueChanged<FollowingDistanceMeasurement>? onFrame;
        await onDashboard(
          tester,
          () async {
            for (var i = 0; i < 17; i++) {
              await drive(tester, 30, 1);
              onFrame!(
                FollowingDistanceMeasurement(
                  timestamp: locations.timestamp,
                  status: FollowingDistanceStatus.tracking,
                  distanceMeters: 13.4112,
                  leadVehicleId: 'lead',
                ),
              );
              await tester.pump();
            }
            expect(speech.spoken, [VoiceAlert.followingDistance.phrase]);
            await stopTrip(tester);
            expect(speech.spoken, [VoiceAlert.followingDistance.phrase]);
            expect(tester.takeException(), isNull);
          },
          mode: mode,
          speedLimitMph: 55,
          cameraBuilder: (_, callback, _) {
            onFrame = callback;
            return const SizedBox();
          },
        );
      },
    );
  }

  for (final mode in [DrivingMode.normal, DrivingMode.navigation]) {
    testWidgets(
      '${mode.apiValue} leaving the app while moving '
      '${mode.tracksFocus ? 'gives one focus alert on return' : 'is silent'}',
      (tester) async {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        await onDashboard(
          tester,
          () async {
            await drive(tester, 30, 3);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
            await drive(tester, 30, 2);
            expect(speech.spoken, isEmpty);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
            expect(
              speech.spoken,
              mode.tracksFocus ? [VoiceAlert.focus.phrase] : isEmpty,
            );
            await drive(tester, 30, 5);
            expect(
              speech.spoken,
              mode.tracksFocus ? [VoiceAlert.focus.phrase] : isEmpty,
            );
            expect(tester.takeException(), isNull);
          },
          mode: mode,
          speedLimitMph: 55,
        );
      },
    );
  }

  testWidgets('starting with voice feedback off speaks nothing', (
    tester,
  ) async {
    ValueChanged<FollowingDistanceMeasurement>? onFrame;
    await onDashboard(
      tester,
      () async {
        for (var i = 0; i < 17; i++) {
          await drive(tester, 32, 1);
          onFrame!(
            FollowingDistanceMeasurement(
              timestamp: locations.timestamp,
              status: FollowingDistanceStatus.tracking,
              distanceMeters: 13.4112,
              leadVehicleId: 'lead',
            ),
          );
          await tester.pump();
        }
        expect(speech.spoken, isEmpty);
        await stopTrip(tester);
        expect(tester.takeException(), isNull);
      },
      mode: DrivingMode.normal,
      speedLimitMph: 25,
      voiceFeedbackEnabled: false,
      cameraBuilder: (_, callback, _) {
        onFrame = callback;
        return const SizedBox();
      },
    );
  });
}
