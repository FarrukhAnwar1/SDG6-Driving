// Central place for API configuration.
//
// Import this wherever you need the backend base URL instead of
// redefining it in each screen:
//
//   import '../widgets/api_config.dart';
//   ...
//   Uri.parse('${ApiConfig.baseUrl}/login')
//
// Which backend you get is controlled at build/run time with
// --dart-define, so you never edit this file to switch environments:
//
//   flutter run --dart-define=ENVIRONMENT=dev        (default if omitted)
//   flutter run --dart-define=ENVIRONMENT=staging
//   flutter run --dart-define=ENVIRONMENT=prod
//
// You can also skip the presets below entirely and point at any
// one-off URL (handy for testing on a physical device):
//
//   flutter run --dart-define=API_BASE_URL=http://192.168.1.23:8000
//
// If both are supplied, API_BASE_URL takes precedence.
class ApiConfig {
  ApiConfig._();
  static const Map<String, String> _urls = {
    'dev': 'http://10.0.2.2:8000', // Android emulator 10.0.2.2:8000 or localhost:8000
    'staging': 'https://staging.example.com',
    'prod': 'https://api.driveucf.com',
  };

  static const String _envName = String.fromEnvironment(
    'ENVIRONMENT',
    defaultValue: 'dev',
  );

  static const String _explicitOverride = String.fromEnvironment(
    'API_BASE_URL',
  );

  static String get baseUrl {
    if (_explicitOverride.isNotEmpty) return _explicitOverride;
    return _urls[_envName] ?? _urls['dev']!;
  }

  static String get environmentName => _envName;
}
