// Tests camera configuration, geometry loading, and lifecycle safeguards.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_geometry.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class _Controller extends YOLOViewController {
  int pauses = 0;
  int resumes = 0;
  int stops = 0;
  bool released = false;
  bool failStop = false;
  final List<double> zoomLevels = [];

  @override
  bool get isInitialized => true;
  @override
  Future<void> setShowOverlays(bool visible) async {}
  @override
  Future<void> setZoomLevel(double zoomLevel) async =>
      zoomLevels.add(zoomLevel);
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> resume() async => resumes++;
  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw PlatformException(code: 'camera_unavailable');
  }

  @override
  void dispose() {
    released = true;
    super.dispose();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late _Controller controller;
  late List<FollowingDistanceMeasurement> measurements;
  late int unavailable;
  late int permissionRequests;
  late int permissionStatus;
  late int geometryReads;
  Map<String, dynamic>? geometryResponse;
  Completer<int>? pendingPermission;
  Completer<Map<String, dynamic>?>? pendingGeometry;

  setUp(() {
    controller = _Controller();
    measurements = [];
    unavailable = 0;
    permissionRequests = 0;
    permissionStatus = 0;
    pendingPermission = null;
    pendingGeometry = null;
    geometryReads = 0;
    geometryResponse = {
      'focalLength': 4.0,
      'imagePlaneWidth': 6.0,
      'imagePlaneHeight': 4.5,
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      (_) async {
        geometryReads++;
        return pendingGeometry?.future ?? geometryResponse;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
      call,
    ) async {
      if (call.method == 'checkPermissionStatus') {
        return pendingPermission == null
            ? permissionStatus
            : pendingPermission!.future;
      }
      if (call.method == 'requestPermissions') permissionRequests++;
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RoadCameraGeometry.channel,
      null,
    );
  });

  Widget camera({
    GlobalKey<FollowingDistanceCameraState>? key,
    bool active = true,
  }) => MaterialApp(
    home: FollowingDistanceCamera(
      key: key,
      active: active,
      controller: controller,
      onMeasurement: measurements.add,
      onUnavailable: () => unavailable++,
    ),
  );

  Map<String, dynamic> frame(int ms) => {
    'timestamp': DateTime.utc(2026, 10, 22, 10).millisecondsSinceEpoch + ms,
    'imageWidth': 480,
    'imageHeight': 640,
    'detections': [
      {
        'className': 'car',
        'confidence': 0.9,
        'normalizedBox': {'left': 0.4, 'top': 0.4, 'right': 0.6, 'bottom': 0.8},
      },
    ],
  };

  testWidgets(
    'unsupported camera can update its parent without a build-phase error',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, updateParent) => FollowingDistanceCamera(
              controller: controller,
              onMeasurement: measurements.add,
              onUnavailable: () => updateParent(() => unavailable++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(unavailable, 1);
      expect(find.byType(YOLOView), findsNothing);
      expect(permissionRequests, 0);
      expect(measurements, isEmpty);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'denied permission reports unavailable without asking during a trip',
    (tester) async {
      await tester.pumpWidget(camera());
      await tester.pumpAndSettle();
      expect(unavailable, 1);
      expect(permissionRequests, 0);
      expect(find.byType(YOLOView), findsNothing);
      expect(measurements, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(controller.released, isTrue);
      expect(controller.stops, 1);
    },
  );

  testWidgets(
    'native detections use the bundled rear-camera model at five FPS; pause and stop reject callbacks',
    (tester) async {
      permissionStatus = 1;
      final key = GlobalKey<FollowingDistanceCameraState>();
      await tester.pumpWidget(camera(key: key));
      // Native model loading is intentionally absent in a widget test, so its
      // loading spinner must not be awaited with pumpAndSettle.
      await tester.pump();
      await tester.pump();
      // The test has no native model loader. Inspect the configured view and
      // deliver the same raw maps that its native event channel would deliver.
      final view = tester.widget<YOLOView>(find.byType(YOLOView));
      expect(
        view.modelPath,
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'assets/models/yolo11n.mlpackage.zip'
            : 'assets/models/yolo11n.tflite',
      );
      expect(view.lensFacing, LensFacing.back);
      expect(view.streamingConfig!.maxFPS, 5);
      expect(view.streamingConfig!.inferenceFrequency, 5);
      expect(view.streamingConfig!.includeOriginalImage, isFalse);
      expect(view.confidenceThreshold, 0.3);
      expect(controller.confidenceThreshold, 0.3);
      final onFrame = view.onStreamingData!;
      onFrame(frame(0));
      await tester.pump();
      onFrame(frame(200));
      onFrame(frame(400));
      expect(measurements, hasLength(3));
      expect(measurements.first.status, FollowingDistanceStatus.waiting);
      expect(measurements.last.distanceMeters, closeTo(8, 0.0001));
      expect(measurements.first.timestamp, DateTime.utc(2026, 10, 22, 10));
      expect(measurements[1].leadVehicleId, measurements.last.leadVehicleId);
      final firstVehicleId = measurements.last.leadVehicleId;
      expect(geometryReads, 1);
      expect(
        controller.zoomLevels,
        defaultTargetPlatform == TargetPlatform.iOS ? [1] : isEmpty,
      );

      await key.currentState!.pause();
      onFrame(frame(600));
      expect(controller.pauses, 1);
      expect(measurements, hasLength(3));
      await key.currentState!.resume();
      await tester.pump();
      onFrame(frame(800));
      await tester.pump();
      onFrame(frame(1000));
      expect(controller.resumes, 1);
      expect(measurements, hasLength(5));
      expect(measurements.last.leadVehicleId, isNot(firstVehicleId));
      expect(geometryReads, 2);

      await key.currentState!.stop();
      await key.currentState!.stop();
      await key.currentState!.resume();
      onFrame(frame(1200));
      expect(controller.stops, 1);
      expect(controller.resumes, 1);
      expect(measurements, hasLength(5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      onFrame(frame(1400));
      expect(measurements, hasLength(5));
      expect(controller.released, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('missing camera geometry cannot generate guessed distances', (
    tester,
  ) async {
    permissionStatus = 1;
    geometryResponse = null;
    await tester.pumpWidget(camera());
    await tester.pump();
    await tester.pump();
    final onFrame = tester
        .widget<YOLOView>(find.byType(YOLOView))
        .onStreamingData!;
    onFrame(frame(0));
    await tester.pump();
    onFrame(frame(200));
    expect(unavailable, greaterThanOrEqualTo(1));
    expect(
      measurements.every((measurement) => measurement.distanceMeters == null),
      isTrue,
    );
    expect(geometryReads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rotation recalculates geometry and restarts the target identity',
    (tester) async {
      permissionStatus = 1;
      await tester.pumpWidget(camera());
      await tester.pump();
      await tester.pump();
      final onFrame = tester
          .widget<YOLOView>(find.byType(YOLOView))
          .onStreamingData!;
      onFrame(frame(0));
      await tester.pump();
      onFrame(frame(200));
      final portrait = measurements.last;
      onFrame({...frame(400), 'imageWidth': 640, 'imageHeight': 480});
      final landscape = measurements.last;
      expect(portrait.distanceMeters, closeTo(8, 1e-9));
      expect(landscape.distanceMeters, closeTo(6, 1e-9));
      expect(landscape.leadVehicleId, isNot(portrait.leadVehicleId));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stale metadata after pause cannot replace the resumed geometry',
    (tester) async {
      permissionStatus = 1;
      final pending = Completer<Map<String, dynamic>?>();
      pendingGeometry = pending;
      final key = GlobalKey<FollowingDistanceCameraState>();
      await tester.pumpWidget(camera(key: key));
      await tester.pump();
      await tester.pump();
      final onFrame = tester
          .widget<YOLOView>(find.byType(YOLOView))
          .onStreamingData!;
      onFrame(frame(0));
      await tester.pump();
      expect(geometryReads, 1);
      await key.currentState!.pause();
      pendingGeometry = null;
      await key.currentState!.resume();
      onFrame(frame(200));
      await tester.pump();
      onFrame(frame(400));
      expect(measurements.last.distanceMeters, closeTo(8, 1e-9));
      pending.complete({
        'focalLength': 8,
        'imagePlaneWidth': 6,
        'imagePlaneHeight': 4.5,
      });
      await tester.pump();
      onFrame(frame(600));
      expect(measurements.last.distanceMeters, closeTo(8, 1e-9));
      expect(geometryReads, 2);
      expect(unavailable, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a permission check completing after stop cannot start inference',
    (tester) async {
      pendingPermission = Completer<int>();
      final key = GlobalKey<FollowingDistanceCameraState>();
      await tester.pumpWidget(camera(key: key));
      await tester.pump();
      await key.currentState!.stop();
      pendingPermission!.complete(1);
      await tester.pumpAndSettle();
      expect(find.byType(YOLOView), findsNothing);
      expect(measurements, isEmpty);
      expect(permissionRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'starting in the background defers the camera; native stop failure still releases its controller',
    (tester) async {
      final key = GlobalKey<FollowingDistanceCameraState>();
      await tester.pumpWidget(camera(key: key, active: false));
      await tester.pumpAndSettle();
      expect(find.byType(YOLOView), findsNothing);
      expect(unavailable, 0);
      await tester.pumpWidget(camera(key: key));
      await tester.pumpAndSettle();
      expect(controller.resumes, 1);
      expect(unavailable, 1);
      controller.failStop = true;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(controller.released, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
