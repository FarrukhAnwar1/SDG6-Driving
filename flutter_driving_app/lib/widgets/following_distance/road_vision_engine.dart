// Runs the bundled road detector and metric-depth network through ONNX Runtime.

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'road_model_input.dart';
import 'road_model_output.dart';

abstract class RoadVisionEngine {
  Future<void> initialize();
  Future<RoadObservation> analyze(RoadCameraFrame frame);
  Future<void> close();
}

class PretrainedRoadVisionEngine implements RoadVisionEngine {
  PretrainedRoadVisionEngine({this.onTiming});

  final void Function(Map<String, Duration> timings)? onTiming;
  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _detector, _depth;
  Future<void>? _initialization;
  Future<RoadObservation>? _running;
  Future<void>? _closing;
  bool _closed = false;

  @override
  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    if (_closed) throw StateError('Road vision engine is closed');
    // CPU gives both platforms a supported fallback for every exported op.
    // A bounded pool avoids monopolizing every core while driving.
    final options = OrtSessionOptions(
      intraOpNumThreads: 4,
      interOpNumThreads: 1,
      providers: [OrtProvider.CPU],
    );
    try {
      _detector = await _runtime.createSessionFromAsset(
        'assets/models/yolop_640.onnx',
        options: options,
      );
      if (_closed) return;
      _depth = await _runtime.createSessionFromAsset(
        'assets/models/unidepth_v2_small.onnx',
        options: options,
      );
      if (!_detector!.inputNames.contains('images') ||
          !_depth!.inputNames.contains('rgbs') ||
          ![
            'det_out',
            'drive_area_seg',
            'lane_line_seg',
          ].every(_detector!.outputNames.contains) ||
          ![
            'depth_meters',
            'confidence',
            'intrinsics',
          ].every(_depth!.outputNames.contains)) {
        throw const FormatException('Unexpected bundled road model contract');
      }
    } catch (_) {
      await _releaseSessions();
      rethrow;
    }
  }

  @override
  Future<RoadObservation> analyze(RoadCameraFrame frame) {
    if (_closed || _detector == null || _depth == null || _running != null) {
      throw StateError('Road vision engine is unavailable or busy');
    }
    final running = _analyze(frame);
    _running = running;
    return running.whenComplete(() => _running = null);
  }

  Future<RoadObservation> _analyze(RoadCameraFrame frame) async {
    final timer = Stopwatch()..start();
    final timings = <String, Duration>{};
    final prepared = await compute(prepareRoadFrame, frame);
    timings['preprocess'] = timer.elapsed;
    timer.reset();
    // Execute sequentially to bound peak native memory. Input timestamps stay
    // attached throughout both networks, rather than being replaced on arrival.
    final detector = await _run(
      _detector!,
      'images',
      prepared.detector,
      [1, 3, detectorSide, detectorSide],
      {
        'det_out': [1, 25200, 6],
        'drive_area_seg': [1, 2, detectorSide, detectorSide],
        'lane_line_seg': [1, 2, detectorSide, detectorSide],
      },
    );
    timings['detector'] = timer.elapsed;
    timer.reset();
    if (_closed) throw StateError('Road vision engine stopped');
    final depth = await _run(
      _depth!,
      'rgbs',
      prepared.depth,
      [1, 3, depthHeight, depthWidth],
      {
        'depth_meters': [1, 1, depthHeight, depthWidth],
        'confidence': [1, 1, depthHeight, depthWidth],
        'intrinsics': [1, 3, 3],
      },
    );
    timings['depth'] = timer.elapsed;
    timer.reset();
    final observation = await compute(
      decodeRoadModels,
      RoadModelOutput(
        frame: prepared,
        detections: detector['det_out']!,
        drivable: detector['drive_area_seg']!,
        lanes: detector['lane_line_seg']!,
        depth: depth['depth_meters']!,
        confidence: depth['confidence']!,
        intrinsics: depth['intrinsics']!,
      ),
    );
    timings['postprocess'] = timer.elapsed;
    onTiming?.call(Map.unmodifiable(timings));
    if (kDebugMode) {
      debugPrint(
        'Road vision timing: ${timings.entries.map((entry) => '${entry.key}=${entry.value.inMilliseconds}ms').join(', ')}',
      );
    }
    return observation;
  }

  Future<Map<String, Float32List>> _run(
    OrtSession session,
    String inputName,
    Float32List pixels,
    List<int> shape,
    Map<String, List<int>> expected,
  ) async {
    final input = await OrtValue.fromList(pixels, shape);
    Map<String, OrtValue> outputs = {};
    try {
      outputs = await session.run({inputName: input});
      final values = <String, Float32List>{};
      for (final entry in expected.entries) {
        final tensor = outputs[entry.key];
        if (tensor == null || !listEquals(tensor.shape, entry.value)) {
          throw FormatException(
            'Invalid ${entry.key} shape: expected ${entry.value}, got ${tensor?.shape}',
          );
        }
        final data = await tensor.asFlattenedList();
        values[entry.key] = data is Float32List
            ? data
            : Float32List.fromList(
                data.map((value) => (value as num).toDouble()).toList(),
              );
      }
      return values;
    } finally {
      for (final value in outputs.values) {
        await value.dispose();
      }
      await input.dispose();
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    // Native tensors/sessions remain alive until their outstanding call ends.
    try {
      await _initialization;
    } catch (_) {
      /* _load released partial resources. */
    }
    try {
      await _running;
    } catch (_) {
      /* Result is discarded by the owner. */
    }
    await _releaseSessions();
  }

  Future<void> _releaseSessions() async {
    final detector = _detector, depth = _depth;
    _detector = null;
    _depth = null;
    try {
      await detector?.close();
    } finally {
      await depth?.close();
    }
  }
}
