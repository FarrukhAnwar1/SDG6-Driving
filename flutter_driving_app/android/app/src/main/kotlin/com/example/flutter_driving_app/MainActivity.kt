package com.example.flutter_driving_app

import android.hardware.camera2.CameraCharacteristics
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "driver_grading/road_camera_geometry",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getGeometry") {
                readRoadCameraGeometry(result)
            } else {
                result.notImplemented()
            }
        }
    }

    @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
    private fun readRoadCameraGeometry(result: MethodChannel.Result) {
        try {
            val providerFuture = ProcessCameraProvider.getInstance(this)
            providerFuture.addListener({
                try {
                    // YOLOView with LensFacing.back and no explicit lens uses
                    // this same CameraX selector. Do not select a camera by ID
                    // ordering or mistake an ultra-wide lens for the main one.
                    val cameraInfo = CameraSelector.DEFAULT_BACK_CAMERA
                        .filter(providerFuture.get().availableCameraInfos)
                        .firstOrNull()
                    if (cameraInfo == null || isDestroyed) {
                        result.success(null)
                        return@addListener
                    }
                    val metadata = Camera2CameraInfo.from(cameraInfo)
                    val sensor = metadata.getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE,
                    )
                    val pixels = metadata.getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE,
                    )
                    val active = metadata.getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE,
                    )
                    val focal = metadata.getCameraCharacteristic(
                        CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS,
                    )?.singleOrNull()
                    // A multi-focal device needs per-frame capture metadata;
                    // never guess which focal length is currently in use.
                    if (sensor == null || pixels == null || active == null || focal == null ||
                        pixels.width <= 0 || pixels.height <= 0
                    ) {
                        result.success(null)
                        return@addListener
                    }
                    val zoom = cameraInfo.zoomState.value?.zoomRatio ?: 1f
                    result.success(mapOf(
                        "focalLength" to (focal * zoom).toDouble(),
                        "imagePlaneWidth" to sensor.width.toDouble() * active.width() / pixels.width,
                        "imagePlaneHeight" to sensor.height.toDouble() * active.height() / pixels.height,
                    ))
                } catch (_: Exception) {
                    result.success(null)
                }
            }, ContextCompat.getMainExecutor(this))
        } catch (_: Exception) {
            result.success(null)
        }
    }
}
