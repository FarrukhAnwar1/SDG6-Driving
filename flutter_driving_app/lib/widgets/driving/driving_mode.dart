import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Trip capabilities shared by the dashboard and completed reports. Settings
// currently exposes Regular and Navigation; its Pocket card is a separate task.
// Navigation excludes focus. Pocket excludes both focus and the road camera.
enum DrivingMode { normal, navigation, pocket }

const _storage = FlutterSecureStorage();
const _drivingModeKey = 'driving_mode';

extension DrivingModeJson on DrivingMode {
  String get apiValue => switch (this) {
    DrivingMode.normal => 'regular',
    DrivingMode.navigation => 'navigation',
    DrivingMode.pocket => 'pocket',
  };

  String get label => switch (this) {
    DrivingMode.normal => 'Normal',
    DrivingMode.navigation => 'Navigation',
    DrivingMode.pocket => 'Pocket',
  };

  bool get tracksFocus => this == DrivingMode.normal;
  bool get tracksFollowingDistance => this != DrivingMode.pocket;

  static DrivingMode fromApiValue(String value) => switch (value) {
    'navigation' => DrivingMode.navigation,
    'pocket' => DrivingMode.pocket,
    _ => DrivingMode.normal,
  };

  Future<void> save() async {
    await _storage.write(key: _drivingModeKey, value: apiValue);
  }
}

Future<DrivingMode> loadDrivingMode() async {
  final storedMode = await _storage.read(key: _drivingModeKey);

  if (storedMode == null) {
    return DrivingMode.normal;
  }

  return DrivingModeJson.fromApiValue(storedMode);
}
