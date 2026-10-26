// Owns one rear-camera preview and raw image stream shared by both networks.

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'road_model_input.dart';

abstract class RoadCameraSource {
  Future<void> start({
    required ValueChanged<RoadCameraFrame> onFrame,
    required VoidCallback onError,
  });
  Widget buildPreview();
  Future<void> close();
}

class FlutterRoadCameraSource implements RoadCameraSource {
  CameraController? _controller;
  bool _closed = false;
  Future<void>? _starting, _closing;

  @override
  Future<void> start({
    required ValueChanged<RoadCameraFrame> onFrame,
    required VoidCallback onError,
  }) => _starting ??= _start(onFrame, onError);

  Future<void> _start(
    ValueChanged<RoadCameraFrame> onFrame,
    VoidCallback onError,
  ) async {
    final cameras = (await availableCameras())
        .where((camera) => camera.lensDirection == CameraLensDirection.back)
        .toList();
    if (_closed) return;
    if (cameras.isEmpty) throw StateError('No rear camera');
    // Prefer the physical normal wide lens, avoiding a telephoto/ultrawide
    // camera when the platform supplies lens metadata. Otherwise use its default.
    final camera = cameras.firstWhere(
      (camera) => camera.lensType == CameraLensType.wide,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    _controller = controller;
    await controller.initialize();
    if (_closed) return;
    await controller.setZoomLevel(1);
    if (_closed) return;
    controller.addListener(() {
      if (!_closed && controller.value.hasError) onError();
    });
    await controller.startImageStream((image) {
      if (_closed) return;
      final format = switch (image.format.group) {
        ImageFormatGroup.bgra8888 => RoadPixelFormat.bgra8888,
        ImageFormatGroup.yuv420 when image.planes.length == 3 =>
          RoadPixelFormat.yuv420,
        _ => null,
      };
      if (format == null) {
        onError();
        return;
      }
      // AVFoundation rotates its video output connection itself. CameraX
      // provides sensor-oriented planes; rotate those using device orientation.
      final orientation = switch (controller.value.deviceOrientation) {
        DeviceOrientation.portraitUp => 0,
        DeviceOrientation.landscapeLeft => 90,
        DeviceOrientation.portraitDown => 180,
        DeviceOrientation.landscapeRight => 270,
      };
      final rotation = defaultTargetPlatform == TargetPlatform.iOS
          ? 0
          : (camera.sensorOrientation - orientation + 360) % 360;
      onFrame(
        RoadCameraFrame(
          width: image.width,
          height: image.height,
          format: format,
          planes: [
            for (final plane in image.planes)
              RoadImagePlane(
                plane.bytes,
                plane.bytesPerRow,
                plane.bytesPerPixel ??
                    (format == RoadPixelFormat.bgra8888 ? 4 : 1),
              ),
          ],
          clockwiseRotation: rotation,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    });
  }

  @override
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _closed) {
      return const SizedBox.shrink();
    }
    final landscape = [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ].contains(controller.value.deviceOrientation);
    final ratio = landscape
        ? controller.value.aspectRatio
        : 1 / controller.value.aspectRatio;
    return SizedBox(
      width: 240,
      height: 240 / ratio,
      child: CameraPreview(controller),
    );
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _starting;
    } catch (_) {
      /* Dispose any partially opened camera. */
    }
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } finally {
      await controller.dispose();
    }
  }
}
