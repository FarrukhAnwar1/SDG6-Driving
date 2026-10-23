import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let geometryChannel = FlutterMethodChannel(
      name: "driver_grading/road_camera_geometry",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    geometryChannel.setMethodCallHandler { call, result in
      guard call.method == "getGeometry" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Match ultralytics_yolo's rear-device preference. This is queried only
      // after its first frame, so activeFormat and zoom describe its session.
      let preferredTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
      ]
      guard let device = preferredTypes.compactMap({
        AVCaptureDevice.default($0, for: .video, position: .back)
      }).first else {
        result(nil)
        return
      }
      let format = device.activeFormat
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let fieldOfView = Double(format.videoFieldOfView)
      guard fieldOfView > 0, fieldOfView < 180, dimensions.width > 0, dimensions.height > 0 else {
        result(nil)
        return
      }
      let focalPixels = Double(dimensions.width) / (2 * tan(fieldOfView * .pi / 360))
      result([
        "focalLength": focalPixels * Double(device.videoZoomFactor),
        "imagePlaneWidth": Double(dimensions.width),
        "imagePlaneHeight": Double(dimensions.height),
      ])
    }
  }
}
