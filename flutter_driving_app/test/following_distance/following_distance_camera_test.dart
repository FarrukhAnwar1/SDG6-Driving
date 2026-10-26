// Checks one-FPS scheduling, lifecycle cancellation and camera/model cleanup.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_source.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_output.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_vision_engine.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/road_vision_fixtures.dart';

class _Source implements RoadCameraSource {
  late ValueChanged<RoadCameraFrame> emit;
  int closes = 0;
  @override
  Future<void> start({
    required ValueChanged<RoadCameraFrame> onFrame,
    required VoidCallback onError,
  }) async {
    emit = onFrame;
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Widget buildPreview() => const SizedBox(
    width: 240,
    height: 320,
    child: ColoredBox(color: Colors.black),
  );
}

class _Engine implements RoadVisionEngine {
  Completer<void>? loading;
  Completer<RoadObservation>? result;
  int calls = 0, closes = 0;
  @override
  Future<void> initialize() async {
    await loading?.future;
  }

  @override
  Future<RoadObservation> analyze(RoadCameraFrame frame) async {
    calls++;
    return result?.future ?? roadScene(frame.timestamp);
  }

  @override
  Future<void> close() async {
    await loading?.future;
    closes++;
  }
}

void main() {
  if (kIsWeb) return;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final start = DateTime.utc(2026, 10, 23);
  late DateTime now;
  late _Engine engine;
  late List<_Source> sources;
  late List<FollowingDistanceMeasurement> measurements;
  late int unavailable, permissionStatus, requests;
  Completer<int>? permission;

  setUp(() {
    now = start;
    engine = _Engine();
    sources = [];
    measurements = [];
    unavailable = 0;
    permissionStatus = 1;
    requests = 0;
    permission = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
      call,
    ) async {
      if (call.method == 'checkPermissionStatus') {
        return permission?.future ?? permissionStatus;
      }
      if (call.method == 'requestPermissions') requests++;
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, null);
  });

  Widget camera({
    GlobalKey<FollowingDistanceCameraState>? key,
    bool active = true,
    VoidCallback? onUnavailable,
  }) => MaterialApp(
    home: FollowingDistanceCamera(
      key: key,
      active: active,
      clock: () => now,
      sourceFactory: () {
        final source = _Source();
        sources.add(source);
        return source;
      },
      engineFactory: () => engine,
      onMeasurement: measurements.add,
      onUnavailable: onUnavailable ?? () => unavailable++,
    ),
  );
  RoadCameraFrame frame(int ms) {
    now = start.add(Duration(milliseconds: ms));
    return RoadCameraFrame(
      width: 2,
      height: 2,
      format: RoadPixelFormat.bgra8888,
      planes: [],
      clockwiseRotation: 0,
      timestamp: now,
    );
  }

  testWidgets(
    'unsupported platforms update the parent after its first build',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => FollowingDistanceCamera(
              onMeasurement: measurements.add,
              onUnavailable: () => update(() => unavailable++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(unavailable, 1);
      expect(tester.takeException(), isNull);
      expect(sources, isEmpty);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'inactive and denied cameras do not load models or request permission',
    (tester) async {
      await tester.pumpWidget(camera(active: false));
      await tester.pumpAndSettle();
      expect(sources, isEmpty);
      expect(unavailable, 0);
      await tester.pumpWidget(const SizedBox());
      permissionStatus = 0;
      await tester.pumpWidget(camera());
      await tester.pumpAndSettle();
      expect(sources, isEmpty);
      expect(unavailable, 1);
      expect(requests, 0);
    },
  );

  testWidgets(
    'inference runs at most once per second while preview stays mounted',
    (tester) async {
      await tester.pumpWidget(camera());
      await tester.pumpAndSettle();
      sources.single.emit(frame(0));
      await tester.pump();
      sources.single.emit(frame(999));
      await tester.pump();
      expect(engine.calls, 1);
      sources.single.emit(frame(1000));
      await tester.pump();
      expect(engine.calls, 2);
      expect(measurements.last.status, FollowingDistanceStatus.tracking);
      expect(measurements.last.timestamp, now);
      expect(measurements.last.distanceMeters, 26.8224);
      expect(find.byIcon(Icons.videocam_off_outlined), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(sources.single.closes, 1);
      expect(engine.closes, 1);
    },
  );

  testWidgets('busy inference drops new frames without creating a backlog', (
    tester,
  ) async {
    engine.result = Completer<RoadObservation>();
    await tester.pumpWidget(camera());
    await tester.pumpAndSettle();
    sources.single.emit(frame(0));
    sources.single.emit(frame(1000));
    sources.single.emit(frame(2000));
    expect(engine.calls, 1);
    engine.result!.complete(roadScene(start));
    await tester.pump();
    expect(engine.calls, 1);
    expect(measurements, hasLength(1));
    engine.result = null;
    sources.single.emit(frame(2100));
    await tester.pump();
    expect(engine.calls, 2);
    expect(measurements.last.timestamp, now);
  });

  testWidgets(
    'expired inference never replaces capture time with arrival time',
    (tester) async {
      engine.result = Completer<RoadObservation>();
      await tester.pumpWidget(camera());
      await tester.pumpAndSettle();
      sources.single.emit(frame(0));
      now = start.add(const Duration(seconds: 6));
      engine.result!.complete(roadScene(start));
      await tester.pump();
      expect(measurements, isEmpty);
      expect(unavailable, 1);
    },
  );

  testWidgets('pause closes the camera and resume ignores the old stream', (
    tester,
  ) async {
    final key = GlobalKey<FollowingDistanceCameraState>();
    await tester.pumpWidget(camera(key: key));
    await tester.pumpAndSettle();
    final old = sources.single;
    old.emit(frame(0));
    await tester.pump();
    await key.currentState!.pause();
    await tester.pump();
    expect(old.closes, 1);
    old.emit(frame(1000));
    await tester.pump();
    expect(engine.calls, 1);
    await key.currentState!.resume();
    await tester.pump();
    old.emit(frame(2000));
    await tester.pump();
    expect(engine.calls, 1);
    sources.last.emit(frame(3000));
    await tester.pump();
    expect(measurements.last.status, FollowingDistanceStatus.tracking);
    await key.currentState!.stop();
    await tester.pump();
    sources.last.emit(frame(4000));
    await tester.pump();
    expect(engine.calls, 2);
    expect(engine.closes, 1);
    expect(sources.every((source) => source.closes == 1), isTrue);
  });

  testWidgets('dispose releases the camera before model loading completes', (
    tester,
  ) async {
    engine.loading = Completer<void>();
    await tester.pumpWidget(camera());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(sources.single.closes, 1);
    expect(engine.closes, 0);
    engine.loading!.complete();
    await tester.pump();
    await tester.pump();
    expect(engine.closes, 1);
    expect(unavailable, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose during permission lookup never opens a camera', (
    tester,
  ) async {
    permission = Completer<int>();
    await tester.pumpWidget(camera());
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    permission!.complete(1);
    await tester.pumpAndSettle();
    expect(sources, isEmpty);
    expect(measurements, isEmpty);
    expect(unavailable, 0);
  });

  testWidgets('a raw camera gap discards even a currently processing frame', (
    tester,
  ) async {
    engine.result = Completer<RoadObservation>();
    await tester.pumpWidget(camera());
    await tester.pumpAndSettle();
    sources.single.emit(frame(0));
    sources.single.emit(frame(2000));
    expect(unavailable, 1);
    engine.result!.complete(roadScene(start));
    await tester.pump();
    expect(measurements, isEmpty);
    engine.result = null;
    sources.single.emit(frame(2100));
    await tester.pump();
    expect(measurements.single.status, FollowingDistanceStatus.tracking);
  });
}
