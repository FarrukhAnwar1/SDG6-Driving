// Runs road-camera vehicle detection and manages camera resources and lifecycle.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'road_camera_geometry.dart';
import 'vehicle_distance_estimator.dart';

typedef FollowingDistanceCameraBuilder =
    Widget Function(
      BuildContext context,
      ValueChanged<FollowingDistanceMeasurement> onMeasurement,
      VoidCallback onUnavailable,
    );

// Owns the native camera/inference view. It streams detections only: no frames
// are saved, sent over the network, or retained in the completed trip.
class FollowingDistanceCamera extends StatefulWidget {
  const FollowingDistanceCamera({
    super.key,
    required this.onMeasurement,
    required this.onUnavailable,
    this.active = true,
    this.controller,
    this.horizontalFieldOfViewDegrees,
  }) : assert(
         horizontalFieldOfViewDegrees == null ||
             (horizontalFieldOfViewDegrees > 0 &&
                 horizontalFieldOfViewDegrees < 180),
       );

  final ValueChanged<FollowingDistanceMeasurement> onMeasurement;
  final VoidCallback onUnavailable;
  final bool active;
  final YOLOViewController? controller;
  // Optional measured FOV for the upright analysis frame. Normally camera
  // metadata supplies this; there is deliberately no guessed default FOV.
  final double? horizontalFieldOfViewDegrees;

  @override
  State<FollowingDistanceCamera> createState() =>
      FollowingDistanceCameraState();
}

class FollowingDistanceCameraState extends State<FollowingDistanceCamera> {
  late final YOLOViewController _controller =
      widget.controller ?? YOLOViewController();
  RoadCameraGeometry? _geometry;
  VehicleDistanceEstimator? _estimator;
  Size? _frameSize;
  bool _permitted = false;
  bool _paused = false;
  bool _stopped = false;
  bool _configured = false;
  bool _configurationReady = false;
  bool _configurationFailed = false;
  int _configurationVersion = 0;

  @override
  void initState() {
    super.initState();
    _paused = !widget.active;
    // Controller.init otherwise replaces the view's confidence with its own
    // default. Seed both settings before the native view attaches.
    unawaited(
      _controller.setConfidenceThreshold(
        VehicleDistanceEstimator.minimumConfidence,
      ),
    );
    unawaited(_controller.setShowOverlays(false));
    // Unsupported platforms report unavailable synchronously. Notify the
    // dashboard only after its first build, when its setState is safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_paused && !_stopped) unawaited(_checkPermission());
    });
  }

  @override
  void didUpdateWidget(FollowingDistanceCamera oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      unawaited(widget.active ? resume() : pause());
    }
  }

  Future<void> _checkPermission() async {
    try {
      if (kIsWeb ||
          (defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.iOS)) {
        _unavailable();
        return;
      }
      // The existing permissions gate requests camera access before a trip.
      // Do not trigger a permission dialog while focus grading is running.
      final permitted = await Permission.camera.isGranted;
      if (!mounted || _stopped || _paused) return;
      setState(() => _permitted = permitted);
      if (!permitted) _unavailable();
    } catch (_) {
      _unavailable();
    }
  }

  Future<void> _configure() async {
    if (_configured || !_controller.isInitialized) return;
    _configured = true;
    final version = _configurationVersion;
    try {
      await _controller.setConfidenceThreshold(
        VehicleDistanceEstimator.minimumConfidence,
      );
      if (!_isCurrentConfiguration(version)) return;
      // Android already starts its default rear camera at native 1x. Calling
      // setZoomLevel there can auto-select a different physical lens, which
      // would invalidate the default-camera metadata. iOS uses one virtual
      // device whose active format/zoom describe the selected constituent.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _controller.setZoomLevel(1);
        if (!_isCurrentConfiguration(version)) return;
      }
      await _controller.setShowOverlays(false);
      if (!_isCurrentConfiguration(version)) return;
      final geometry = widget.horizontalFieldOfViewDegrees == null
          ? await RoadCameraGeometry.read()
          : null;
      if (!_isCurrentConfiguration(version)) return;
      _geometry = geometry;
      if (geometry == null && widget.horizontalFieldOfViewDegrees == null) {
        _configurationFailed = true;
        _unavailable();
      } else {
        _configurationReady = true;
      }
    } catch (_) {
      if (version == _configurationVersion) {
        _configurationFailed = true;
        _unavailable();
      }
    }
  }

  bool _isCurrentConfiguration(int version) =>
      mounted && !_stopped && !_paused && version == _configurationVersion;

  void _onFrame(Map<String, dynamic> data) {
    if (!mounted || _stopped || _paused) return;
    unawaited(_configure());
    try {
      final timestamp = data['timestamp'];
      final detections = data['detections'];
      final width = data['imageWidth'];
      final height = data['imageHeight'];
      if (timestamp is! num ||
          !timestamp.isFinite ||
          detections is! List ||
          width is! num ||
          height is! num ||
          !width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0) {
        _unavailable();
        return;
      }
      final frameTime = DateTime.fromMillisecondsSinceEpoch(
        timestamp.round(),
        isUtc: true,
      );
      if (_configurationFailed) {
        _unavailable();
        return;
      }
      if (!_configurationReady) {
        widget.onMeasurement(
          FollowingDistanceMeasurement(
            timestamp: frameTime,
            status: FollowingDistanceStatus.waiting,
          ),
        );
        return;
      }
      final frameSize = Size(width.toDouble(), height.toDouble());
      if (_estimator == null || frameSize != _frameSize) {
        final fieldOfView = widget.horizontalFieldOfViewDegrees;
        if (fieldOfView != null) {
          _estimator = VehicleDistanceEstimator.fromHorizontalFieldOfView(
            fieldOfView,
          );
        } else {
          final focalLength = _geometry!.normalizedFocalLengthFor(frameSize);
          if (focalLength == null ||
              !focalLength.isFinite ||
              focalLength <= 0) {
            _unavailable();
            return;
          }
          _estimator = VehicleDistanceEstimator(
            normalizedFocalLength: focalLength,
          );
        }
        _frameSize = frameSize;
      }
      final vehicles = detections.map((item) {
        if (item is! Map ||
            item['className'] is! String ||
            item['confidence'] is! num ||
            item['normalizedBox'] is! Map) {
          throw const FormatException('Invalid detection');
        }
        final box = item['normalizedBox'] as Map;
        return VehicleDetection(
          label: item['className'] as String,
          confidence: (item['confidence'] as num).toDouble(),
          normalizedBox: Rect.fromLTRB(
            (box['left'] as num).toDouble(),
            (box['top'] as num).toDouble(),
            (box['right'] as num).toDouble(),
            (box['bottom'] as num).toDouble(),
          ),
        );
      }).toList();
      widget.onMeasurement(
        _estimator!.estimate(
          detections: vehicles,
          // Both native runtimes send epoch milliseconds, not arrival time.
          timestamp: frameTime,
        ),
      );
    } catch (_) {
      _unavailable();
    }
  }

  void _unavailable() {
    _estimator?.reset();
    if (mounted && !_stopped && !_paused) widget.onUnavailable();
  }

  Future<void> pause() async {
    if (_paused || _stopped) return;
    _paused = true;
    _resetGeometry();
    try {
      await _controller.pause();
    } catch (_) {
      // The view may still be loading; its lifecycle also pauses the camera.
    }
  }

  Future<void> resume() async {
    if (_stopped || !_paused) return;
    _paused = false;
    _resetGeometry();
    try {
      await _controller.resume();
      if (mounted && !_stopped) await _checkPermission();
    } catch (_) {
      _unavailable();
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _resetGeometry();
    try {
      await _controller.stop().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Platform view disposal also releases the native camera and model.
    }
  }

  void _resetGeometry() {
    _configurationVersion++;
    _configured = false;
    _configurationReady = false;
    _configurationFailed = false;
    _geometry = null;
    _frameSize = null;
    // Each estimator has its own identity namespace, including after a change
    // of frame dimensions or lifecycle restart.
    _estimator = null;
  }

  @override
  void dispose() {
    unawaited(stop());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Road camera preview',
      image: true,
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: !_permitted || _stopped
              ? const ColoredBox(
                  color: Colors.black12,
                  child: Center(child: Icon(Icons.videocam_off_outlined)),
                )
              : FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: 240,
                    height: 160,
                    child: YOLOView(
                      controller: _controller,
                      modelPath: defaultTargetPlatform == TargetPlatform.iOS
                          ? 'assets/models/yolo11n.mlpackage.zip'
                          : 'assets/models/yolo11n.tflite',
                      task: YOLOTask.detect,
                      lensFacing: LensFacing.back,
                      confidenceThreshold:
                          VehicleDistanceEstimator.minimumConfidence,
                      onStreamingData: _onFrame,
                      onModelError: (_, _, _) => _unavailable(),
                      streamingConfig: const YOLOStreamingConfig(
                        includeDetections: true,
                        includeClassifications: false,
                        includeProcessingTimeMs: false,
                        includeFps: false,
                        includeOriginalImage: false,
                        inferenceFrequency: 5,
                        maxFPS: 5,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
