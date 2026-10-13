// Driving modes the user can start a trip in. Focused Driving is only
// graded in "normal" mode, since checking a navigation app while driving
// in "navigation" mode isn't a distraction the same way.
enum DrivingMode { normal, navigation }

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
}