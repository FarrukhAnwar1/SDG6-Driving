import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Driving modes the user can start a trip in. Focused Driving is only
// graded in "normal" mode, since checking a navigation app while driving
// in "navigation" mode isn't a distraction the same way.
enum DrivingMode { normal, navigation }

const _storage = FlutterSecureStorage();
const _drivingModeKey = 'driving_mode';

extension DrivingModeJson on DrivingMode {
  String get apiValue => switch (this) {
    DrivingMode.normal => 'regular',
    DrivingMode.navigation => 'navigation',
  };

  String get label => switch (this) {
    DrivingMode.normal => 'Normal',
    DrivingMode.navigation => 'Navigation',
  };

  static DrivingMode fromApiValue(String value) => switch (value) {
    'navigation' => DrivingMode.navigation,
    _ => DrivingMode.normal,
  };

  Future<void> save() async {
    await _storage.write(
      key: _drivingModeKey,
      value: apiValue,
    );
  }
}

Future<DrivingMode> loadDrivingMode() async {
  final storedMode = await _storage.read(
  key: _drivingModeKey,
);

if (storedMode == null) {
  return DrivingMode.normal;
}

  return DrivingModeJson.fromApiValue(storedMode);
}
