// Coordinates the road camera, pretrained inference, one-FPS sampling and cleanup.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'following_distance_monitoring_service.dart';
import 'following_distance_grading_service.dart';
import 'road_camera_source.dart';
import 'road_model_input.dart';
import 'road_vision_engine.dart';
import 'vehicle_distance_estimator.dart';

typedef FollowingDistanceCameraBuilder =
    Widget Function(
      BuildContext context,
      ValueChanged<FollowingDistanceMeasurement> onMeasurement,
      VoidCallback onUnavailable,
    );

class FollowingDistanceCamera extends StatefulWidget {
  const FollowingDistanceCamera({
    super.key,
    required this.onMeasurement,
    required this.onUnavailable,
    this.onProcessingStarted,
    this.active = true,
    this.sourceFactory,
    this.engineFactory,
    this.clock,
  });
  final ValueChanged<FollowingDistanceMeasurement> onMeasurement;
  final VoidCallback onUnavailable;
  final ValueChanged<DateTime>? onProcessingStarted;
  final bool active;
  final RoadCameraSource Function()? sourceFactory;
  final RoadVisionEngine Function()? engineFactory;
  final DateTime Function()? clock;

  @override
  State<FollowingDistanceCamera> createState() =>
      FollowingDistanceCameraState();
}

class FollowingDistanceCameraState extends State<FollowingDistanceCamera> {
  static const analysisInterval = Duration(seconds: 1);
  final _estimator = VehicleDistanceEstimator();
  RoadCameraSource? _source;
  RoadVisionEngine? _engine;
  Future<void> _cameraCleanup = Future.value();
  Future<void>? _stopping;
  DateTime? _lastStarted;
  DateTime? _lastRawFrameTime;
  int _measurementEpoch = 0;
  bool _ready = false,
      _busy = false,
      _paused = false,
      _stopped = false,
      _disposing = false;
  int _version = 0;
  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _paused = !widget.active;
    // Unsupported/denied callbacks may update the parent. Wait until after its
    // build, including the browser placeholder used for simple web debugging.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_paused) unawaited(_start());
    });
  }

  @override
  void didUpdateWidget(FollowingDistanceCamera oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      unawaited(widget.active ? resume() : pause());
    }
  }

  bool _current(int version) =>
      mounted && !_stopped && !_paused && version == _version;

  Future<void> _start() async {
    final version = ++_version;
    try {
      if (kIsWeb ||
          ![
            TargetPlatform.android,
            TargetPlatform.iOS,
          ].contains(defaultTargetPlatform)) {
        _unavailable(version);
        return;
      }
      // The app's existing permissions gate handles requests before a trip.
      final granted = await Permission.camera.isGranted;
      if (!_current(version)) return;
      if (!granted) {
        _unavailable(version);
        return;
      }
      await _cameraCleanup;
      if (!_current(version)) return;
      final source = widget.sourceFactory?.call() ?? FlutterRoadCameraSource();
      _source = source;
      final engine = _engine ??=
          widget.engineFactory?.call() ?? PretrainedRoadVisionEngine();
      await source.start(
        onFrame: (frame) => _onFrame(frame, version),
        onError: () => _unavailable(version),
      );
      if (!_current(version)) return;
      setState(() {});
      await engine.initialize();
      if (!_current(version)) return;
      _ready = true;
    } catch (error, stack) {
      debugPrint('Road monitoring could not start: $error\n$stack');
      if (_current(version)) {
        _unavailable(version);
        await _releaseCamera();
        final engine = _engine;
        _engine = null;
        await engine?.close();
      }
    }
  }

  void _onFrame(RoadCameraFrame frame, int version) {
    if (!_current(version)) return;
    if (_lastRawFrameTime != null) {
      if (!frame.timestamp.isAfter(_lastRawFrameTime!)) return;
      if (frame.timestamp.difference(_lastRawFrameTime!) >
          FollowingDistanceGradingService.maxSampleGap) {
        _measurementEpoch++;
        _unavailable(version);
      }
    }
    _lastRawFrameTime = frame.timestamp;
    if (!_ready || _busy) return;
    if (_lastStarted != null &&
        frame.timestamp.difference(_lastStarted!) < analysisInterval) {
      return;
    }
    _lastStarted = frame.timestamp;
    _busy = true;
    widget.onProcessingStarted?.call(frame.timestamp);
    // No queue: camera frames arriving during inference are deliberately dropped.
    unawaited(
      _analyze(
        frame,
        version,
        _measurementEpoch,
      ).whenComplete(() => _busy = false),
    );
  }

  Future<void> _analyze(RoadCameraFrame frame, int version, int epoch) async {
    try {
      final observation = await _engine!.analyze(frame);
      if (!_current(version) || epoch != _measurementEpoch) return;
      final age = _now.difference(frame.timestamp);
      if (observation.timestamp != frame.timestamp ||
          age > FollowingDistanceMonitoringService.maxMeasurementAge ||
          age < const Duration(milliseconds: -100)) {
        debugPrint(
          'Road measurement rejected: age=${age.inMilliseconds}ms, limit=${FollowingDistanceMonitoringService.maxMeasurementAge.inMilliseconds}ms, captureTimeMatches=${observation.timestamp == frame.timestamp}',
        );
        _unavailable(version);
        return;
      }
      widget.onMeasurement(_estimator.estimate(observation));
    } catch (error, stack) {
      debugPrint('Road measurement unavailable: $error\n$stack');
      _unavailable(version);
    }
  }

  void _unavailable(int version) {
    if (!_current(version)) return;
    _estimator.reset();
    widget.onUnavailable();
  }

  Future<void> _releaseCamera() {
    final source = _source;
    _source = null;
    _ready = false;
    if (mounted && !_disposing) setState(() {});
    return _cameraCleanup = _cameraCleanup.then((_) async {
      try {
        await source?.close();
      } catch (error) {
        debugPrint('Road camera cleanup: $error');
      }
    });
  }

  Future<void> pause() async {
    if (_paused || _stopped) return;
    _paused = true;
    _version++;
    _lastStarted = null;
    _lastRawFrameTime = null;
    _estimator.reset();
    await _releaseCamera();
  }

  Future<void> resume() async {
    if (_stopped || !_paused) return;
    _paused = false;
    _lastStarted = null;
    _lastRawFrameTime = null;
    await _start();
  }

  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    _stopped = true;
    _version++;
    _estimator.reset();
    // Release the camera first; model cleanup waits for any native inference.
    await _releaseCamera();
    final engine = _engine;
    _engine = null;
    try {
      await engine?.close();
    } catch (error) {
      debugPrint('Road model cleanup: $error');
    }
  }

  @override
  void dispose() {
    // Avoid setState from the asynchronous cleanup during element unmounting.
    _disposing = true;
    _stopped = true;
    final source = _source;
    _source = null;
    if (source != null) {
      _cameraCleanup = _cameraCleanup.then((_) => source.close()).catchError((
        Object error,
      ) {
        debugPrint('Road camera cleanup: $error');
      });
    }
    unawaited(stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Road camera preview',
    image: true,
    child: IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _source == null || _stopped
            ? const ColoredBox(
                color: Colors.black12,
                child: Center(child: Icon(Icons.videocam_off_outlined)),
              )
            : FittedBox(fit: BoxFit.cover, child: _source!.buildPreview()),
      ),
    ),
  );
}
