// Local-only diagnostic. Reuses production inference, selection and grading.
// Configuration and results live in the app-specific external benchmark folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_grading_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_monitoring_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_camera_source.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_input.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_vision_engine.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';

void main() => runApp(const MaterialApp(home: _Benchmark()));

PreparedRoadFrame _prepareLetterboxBaseline(RoadCameraFrame frame) =>
    prepareRoadFrame(frame, cropDepth: false);

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final _key = GlobalKey<FollowingDistanceCameraState>();
  final _monitor = FollowingDistanceMonitoringService(
    drivingMode: DrivingMode.normal,
  );
  File? _events;
  Directory? _root;
  FlutterRoadCameraSource? _cameraOnly;
  bool _vision = false;
  String _phase = 'starting';
  int _completed = 0;
  Map<String, int> _timings = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _log(String event, [Map<String, Object?> data = const {}]) {
    final row = {
      'event': event,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...data,
    };
    final line = jsonEncode(row);
    _events?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    debugPrint('FD_BENCH $line');
  }

  void _setPhase(String phase) {
    if (mounted) setState(() => _phase = phase);
    _log('phase', {'phase': phase});
  }

  void _gps() => _monitor.updatePosition(
    speedMph: 90,
    latitude: 40,
    longitude: -75,
    timestamp: DateTime.now().toUtc(),
  );

  Future<void> _run() async {
    try {
      if (!Platform.isAndroid) {
        throw UnsupportedError('This ADB benchmark supports Android');
      }
      final cache = await getTemporaryDirectory();
      final root = Directory('${cache.path}/following_distance_benchmark');
      await root.create(recursive: true);
      _root = root;
      final configFile = File('${root.path}/config.json');
      final config = configFile.existsSync()
          ? jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      final mode = config['mode'] as String? ?? 'memory';
      _events = File('${root.path}/$mode-events.jsonl');
      _events!.writeAsStringSync('');
      _log('start', {
        'mode': mode,
        'root': root.path,
        'pid': pid,
        'runtime': Platform.version,
        'cpuCount': Platform.numberOfProcessors,
      });
      if (mode == 'dataset') {
        await _dataset(baseline: config['baseline'] == true);
      } else {
        await _memory((config['visionSeconds'] as num?)?.toInt() ?? 90);
      }
      _setPhase('done');
    } catch (error, stack) {
      _log('error', {'error': '$error', 'stack': '$stack'});
      if (mounted) setState(() => _phase = 'ERROR: $error');
    }
  }

  Future<void> _memory(int visionSeconds) async {
    _setPhase('idle');
    await Future<void>.delayed(const Duration(seconds: 12));
    _setPhase('camera_only_start');
    final source = FlutterRoadCameraSource();
    _cameraOnly = source;
    var frames = 0;
    await source.start(
      onFrame: (frame) {
        frames++;
        if (frames == 1) {
          _log('raw_frame', {
            'width': frame.width,
            'height': frame.height,
            'rotation': frame.clockwiseRotation,
          });
        }
      },
      onError: () => _log('camera_error'),
    );
    _setPhase('camera_only');
    await Future<void>.delayed(const Duration(seconds: 18));
    await source.close();
    _cameraOnly = null;
    _setPhase('camera_switch');
    await Future<void>.delayed(const Duration(seconds: 3));
    _monitor.resume();
    _gps();
    final gps = Timer.periodic(const Duration(seconds: 1), (_) => _gps());
    final watchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _monitor.checkForInterruption(),
    );
    _setPhase('vision_start');
    if (mounted) setState(() => _vision = true);
    try {
      await Future<void>.delayed(Duration(seconds: visionSeconds));
      _setPhase('vision_stop');
      await _key.currentState?.stop();
    } finally {
      gps.cancel();
      watchdog.cancel();
      _monitor.finalizeTrip();
    }
    if (mounted) setState(() => _vision = false);
    _setPhase('released');
    await Future<void>.delayed(const Duration(seconds: 10));
    _log('memory_complete', {
      'completedFrames': _completed,
      'cameraOnlyFrames': frames,
    });
  }

  Future<RoadCameraFrame> _readFrame(Map<String, dynamic> row) async {
    final path = '${_root!.path}/dataset/${row['image']}';
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
    );
    final decoded = await codec.getNextFrame();
    final image = decoded.image;
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final pixels = Uint8List.fromList(
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
    );
    for (var i = 0; i < pixels.length; i += 4) {
      final red = pixels[i];
      pixels[i] = pixels[i + 2];
      pixels[i + 2] = red;
    }
    final frame = RoadCameraFrame(
      width: image.width,
      height: image.height,
      format: RoadPixelFormat.bgra8888,
      planes: [RoadImagePlane(pixels, image.width * 4, 4)],
      clockwiseRotation: 0,
      timestamp: DateTime.fromMicrosecondsSinceEpoch(
        (row['timestampUs'] as num).toInt(),
        isUtc: true,
      ),
    );
    image.dispose();
    codec.dispose();
    return frame;
  }

  Future<void> _dataset({required bool baseline}) async {
    final manifest =
        jsonDecode(
              await File('${_root!.path}/dataset/manifest.json').readAsString(),
            )
            as Map<String, dynamic>;
    final rows = (manifest['frames'] as List).cast<Map<String, dynamic>>();
    final output = File('${_root!.path}/predictions.jsonl');
    output.writeAsStringSync('');
    final engine = PretrainedRoadVisionEngine(
      framePreparer: baseline ? _prepareLetterboxBaseline : prepareRoadFrame,
      onTiming: (timings) {
        _timings = timings.map(
          (key, value) => MapEntry(key, value.inMicroseconds),
        );
      },
    );
    _setPhase('dataset_load');
    _log('preprocessing', {'baseline': baseline});
    await engine.initialize();
    _setPhase('dataset');
    var estimator = VehicleDistanceEstimator();
    var grading = FollowingDistanceGradingService();
    String? previousSequence;
    try {
      for (final row in rows) {
        if (previousSequence != row['sequence']) {
          estimator = VehicleDistanceEstimator();
          grading = FollowingDistanceGradingService();
          previousSequence = row['sequence'] as String;
        }
        final timer = Stopwatch()..start();
        final frame = await _readFrame(row);
        final decodeUs = timer.elapsedMicroseconds;
        timer.reset();
        final observation = await engine.analyze(frame);
        final measurement = estimator.estimate(observation);
        final inferenceUs = timer.elapsedMicroseconds;
        grading.addSample(
          speedMph: (row['speedMph'] as num).toDouble(),
          distanceMeters: measurement.distanceMeters,
          timestamp: frame.timestamp,
          latitude: (row['latitude'] as num).toDouble(),
          longitude: (row['longitude'] as num).toDouble(),
          leadVehicleId: measurement.leadVehicleId,
        );
        final prediction = <String, Object?>{
          'id': row['id'],
          'sequence': row['sequence'],
          'timestampUs': row['timestampUs'],
          'status': measurement.status.name,
          'distanceMeters': measurement.distanceMeters,
          'leadVehicleId': measurement.leadVehicleId,
          'roadVisible': observation.roadVisible,
          'grade': grading.grade,
          'isPenalizing': grading.isPenalizing,
          'requiredHeadwaySeconds':
              FollowingDistanceGradingService.requiredHeadwaySeconds,
          'inferenceUs': inferenceUs,
          'imageDecodeUs': decodeUs,
          'timingsUs': _timings,
          'vehicles': [
            for (final vehicle in observation.vehicles)
              {
                'box': [
                  vehicle.detection.normalizedBox.left,
                  vehicle.detection.normalizedBox.top,
                  vehicle.detection.normalizedBox.right,
                  vehicle.detection.normalizedBox.bottom,
                ],
                'confidence': vehicle.detection.confidence,
                'inEgoLane': vehicle.inEgoLane,
                'distanceMeters': vehicle.distanceMeters,
              },
          ],
        };
        output.writeAsStringSync(
          '${jsonEncode(prediction)}\n',
          mode: FileMode.append,
          flush: true,
        );
        _completed++;
        _log('prediction', {
          'id': row['id'],
          'completed': _completed,
          'total': rows.length,
          'status': measurement.status.name,
          'distanceMeters': measurement.distanceMeters,
          'inferenceUs': inferenceUs,
        });
        if (mounted) setState(() {});
      }
    } finally {
      await engine.close();
    }
    _log('dataset_complete', {'frames': _completed});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Following-distance benchmark')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Local diagnostic. Synthetic GPS; no trip or upload.'),
        ),
        Text('Phase: $_phase'),
        Text('Frames completed: $_completed'),
        if (_cameraOnly != null)
          SizedBox(width: 240, height: 240, child: _cameraOnly!.buildPreview()),
        if (_vision)
          SizedBox(
            width: 240,
            height: 240,
            child: FollowingDistanceCamera(
              key: _key,
              engineFactory: () => PretrainedRoadVisionEngine(
                onTiming: (timings) {
                  _log('timing', {
                    'microseconds': timings.map(
                      (key, value) => MapEntry(key, value.inMicroseconds),
                    ),
                  });
                },
              ),
              onProcessingStarted: _monitor.beginMeasurement,
              onUnavailable: () {
                _monitor.cameraUnavailable();
                _log('unavailable');
              },
              onMeasurement: (measurement) {
                _monitor.addMeasurement(measurement);
                _completed++;
                _log('measurement', {
                  'status': measurement.status.name,
                  'monitorStatus': _monitor.status.name,
                  'ageMs': _monitor.measurementAge?.inMilliseconds,
                });
                if (mounted) setState(() {});
              },
            ),
          ),
      ],
    ),
  );
}
