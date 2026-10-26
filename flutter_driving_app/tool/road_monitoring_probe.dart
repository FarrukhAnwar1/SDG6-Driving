// Runs parked-phone checks with public test frames or the rear camera and synthetic GPS.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_source.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';

void main() {
  runApp(const MaterialApp(home: _MonitoringProbe()));
}

class _FixtureCamera implements RoadCameraSource {
  _FixtureCamera(this.planes);
  final List<RoadImagePlane> planes;
  Timer? _timer;
  @override
  Future<void> start({
    required ValueChanged<RoadCameraFrame> onFrame,
    required VoidCallback onError,
  }) async {
    _timer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => onFrame(
        RoadCameraFrame(
          width: 640,
          height: 480,
          format: RoadPixelFormat.yuv420,
          planes: planes,
          clockwiseRotation: 90,
          timestamp: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  @override
  Widget buildPreview() => const SizedBox(
    width: 240,
    height: 320,
    child: ColoredBox(color: Colors.black),
  );
  @override
  Future<void> close() async {
    _timer?.cancel();
  }
}

class _MonitoringProbe extends StatefulWidget {
  const _MonitoringProbe();
  @override
  State<_MonitoringProbe> createState() => _MonitoringProbeState();
}

class _MonitoringProbeState extends State<_MonitoringProbe> {
  final _monitor = FollowingDistanceMonitoringService(
    drivingMode: DrivingMode.normal,
  );
  final _cameraKey = GlobalKey<FollowingDistanceCameraState>();
  final _lines = <String>[
    _liveCamera
        ? 'Local test: rear camera, simulated 90 mph.'
        : 'Local test: fixed public image, simulated 90 mph.',
  ];
  List<RoadImagePlane>? _planes;
  Timer? _gps, _watchdog, _deadline;
  int _tracked = 0, _unavailable = 0;
  int _completed = 0;
  static const _liveCamera = bool.fromEnvironment('ROAD_PROBE_LIVE_CAMERA');
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _log(String message) {
    debugPrint('ROAD_MONITOR_PROBE $message');
    if (mounted) setState(() => _lines.add(message));
  }

  void _position() => _monitor.updatePosition(
    speedMph: 90,
    latitude: 40,
    longitude: -75,
    timestamp: DateTime.now().toUtc(),
  );

  Future<void> _prepare() async {
    try {
      const path = String.fromEnvironment(
        'ROAD_PROBE_INPUT',
        defaultValue:
            '/data/user/0/com.example.flutter_driving_app/cache/road_probe_yuv420.bin',
      );
      final bytes = _liveCamera
          ? Uint8List(640 * 480 * 3 ~/ 2)
          : await File(path).readAsBytes();
      if (bytes.length != 640 * 480 * 3 ~/ 2) {
        throw const FormatException('Invalid fixture size');
      }
      _monitor.resume();
      _position();
      _gps = Timer.periodic(const Duration(seconds: 1), (_) => _position());
      _watchdog = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _monitor.checkForInterruption(),
      );
      _deadline = Timer(const Duration(seconds: 22), _finish);
      if (mounted) {
        setState(
          () => _planes = [
            RoadImagePlane(Uint8List.sublistView(bytes, 0, 640 * 480), 640, 1),
            RoadImagePlane(
              Uint8List.sublistView(bytes, 640 * 480, 640 * 480 + 320 * 240),
              320,
              1,
            ),
            RoadImagePlane(
              Uint8List.sublistView(bytes, 640 * 480 + 320 * 240),
              320,
              1,
            ),
          ],
        );
      }
    } catch (error) {
      _log('FAIL: $error');
    }
  }

  Future<void> _finish() async {
    _finished = true;
    _gps?.cancel();
    _watchdog?.cancel();
    _monitor.finalizeTrip();
    await _cameraKey.currentState?.stop();
    final passed =
        _unavailable == 0 &&
        (_liveCamera
            ? _completed >= 3
            : _tracked >= 3 &&
                  _monitor.grade! < 100 &&
                  _monitor.violations.isNotEmpty);
    _log(
      '${passed ? 'PASS' : 'FAIL'}: completed=$_completed tracked=$_tracked unavailable=$_unavailable grade=${_monitor.grade} violations=${_monitor.violations.length}',
    );
  }

  @override
  void dispose() {
    _finished = true;
    _gps?.cancel();
    _watchdog?.cancel();
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Road grading diagnostic')),
    body: Column(
      children: [
        if (_planes != null)
          SizedBox(
            width: 64,
            height: 44,
            child: FollowingDistanceCamera(
              key: _cameraKey,
              sourceFactory: () => _liveCamera
                  ? FlutterRoadCameraSource()
                  : _FixtureCamera(_planes!),
              onProcessingStarted: _monitor.beginMeasurement,
              onUnavailable: () {
                if (!_finished) {
                  _unavailable++;
                  _monitor.cameraUnavailable();
                  _log('Unavailable');
                }
              },
              onMeasurement: (measurement) {
                if (_finished) return;
                _monitor.addMeasurement(measurement);
                _completed++;
                if (_monitor.status == FollowingDistanceStatus.unavailable) {
                  _unavailable++;
                }
                if (_monitor.status == FollowingDistanceStatus.tracking) {
                  _tracked++;
                }
                _log(
                  '${_monitor.status.name}: headway=${_monitor.headwaySeconds?.toStringAsFixed(2)} age=${_monitor.measurementAge?.inMilliseconds}ms grade=${_monitor.grade?.toStringAsFixed(2)}',
                );
              },
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(_lines.join('\n\n')),
          ),
        ),
      ],
    ),
  );
}
