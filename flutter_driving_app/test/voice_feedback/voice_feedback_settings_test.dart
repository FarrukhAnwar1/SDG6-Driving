// Tests voice feedback preference persistence, defaults, and failed saves.
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_feedback_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> stored;
  late bool failWrites;
  setUp(() {
    stored = {};
    failWrites = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      if (call.method == 'read') return stored[key];
      if (failWrites) throw PlatformException(code: 'write_failed');
      stored[key] = arguments['value'] as String;
      return null;
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('defaults to enabled and restores a saved off preference', () async {
    final settings = VoiceFeedbackSettings();
    await settings.load();
    expect(settings.value, isTrue);
    await settings.setEnabled(false);

    final restartedSettings = VoiceFeedbackSettings();
    await restartedSettings.load();
    expect(restartedSettings.value, isFalse);
    await restartedSettings.setEnabled(true);
    await settings.load();
    expect(settings.value, isTrue);
  });

  test('failed saves preserve the active preference and allow retry', () async {
    failWrites = true;
    final settings = VoiceFeedbackSettings();
    await expectLater(
      settings.setEnabled(false),
      throwsA(isA<PlatformException>()),
    );
    expect(settings.value, isTrue);
    expect(settings.isSaving, isFalse);

    failWrites = false;
    await settings.setEnabled(false);
    expect(settings.value, isFalse);
  });
}
