// Tests theme colors, saved preferences, daylight selection, and save failures.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/theme/app_theme.dart';
import 'package:flutter_driving_app/widgets/theme/solar_daylight.dart';
import 'package:flutter_driving_app/widgets/theme/theme_settings.dart';
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

  test('uses the exact requested backgrounds and primary green', () {
    expect(AppTheme.light.scaffoldBackgroundColor, const Color(0xfff5f5f5));
    expect(AppTheme.dark.scaffoldBackgroundColor, const Color(0xff1b1b1b));
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      expect(theme.colorScheme.primary, const Color(0xff074907));
      expect(theme.colorScheme.onPrimary, Colors.white);
    }
  });

  test(
    'defaults to manual dark and restores both preferences on restart',
    () async {
      final settings = ThemeSettings();
      await settings.load();
      expect(settings.autoSwitch, isFalse);
      expect(settings.themeMode, ThemeMode.dark);
      await settings.setDark(false);
      await settings.setAutoSwitch(true);

      final restored = ThemeSettings();
      await restored.load();
      expect(restored.autoSwitch, isTrue);
      expect(restored.waitingForLocation, isTrue);
      expect(restored.themeMode, ThemeMode.dark);
      await restored.setDark(true); // Manual changes are ignored in auto mode.
      await restored.setAutoSwitch(false);
      expect(restored.themeMode, ThemeMode.light);
    },
  );

  test('auto follows sunrise/sunset, date, and location changes', () async {
    var now = DateTime.utc(2026, 3, 20, 5);
    final settings = ThemeSettings(clock: () => now);
    await settings.setAutoSwitch(true);
    expect(settings.isDark, isTrue);
    settings.updateLocation(0, 0);
    expect(settings.waitingForLocation, isFalse);
    expect(settings.isDark, isTrue);
    now = DateTime.utc(2026, 3, 20, 7);
    settings.refreshDaylight();
    expect(settings.isDark, isFalse);
    now = DateTime.utc(2026, 3, 20, 19);
    settings.refreshDaylight();
    expect(settings.isDark, isTrue);
    settings.updateLocation(0, 179);
    expect(settings.isDark, isFalse);
    now = DateTime.utc(2026, 3, 21, 12);
    settings.updateLocation(0, 0);
    expect(settings.isDark, isFalse);
  });

  test('failed save preserves the current theme and allows retry', () async {
    failWrites = true;
    final settings = ThemeSettings();
    await expectLater(
      settings.setDark(false),
      throwsA(isA<PlatformException>()),
    );
    expect(settings.isDark, isTrue);
    expect(settings.isSaving, isFalse);
    failWrites = false;
    await settings.setDark(false);
    expect(settings.isDark, isFalse);
  });

  test('invalid stored preferences use the requested defaults', () async {
    stored[ThemeSettings.storageKey] = '{bad';
    final settings = ThemeSettings();
    await settings.load();
    expect(settings.autoSwitch, isFalse);
    expect(settings.isDark, isTrue);
  });

  test('solar horizon includes seasonal, polar, and date-line behavior', () {
    // At Greenwich on the equinox, sunrise is shortly after 06:00 UTC.
    expect(isSolarDaylight(DateTime.utc(2026, 3, 20, 6), 0, 0), isFalse);
    expect(isSolarDaylight(DateTime.utc(2026, 3, 20, 6, 10), 0, 0), isTrue);
    expect(isSolarDaylight(DateTime.utc(2026, 3, 20, 18), 0, 0), isTrue);
    expect(isSolarDaylight(DateTime.utc(2026, 3, 20, 18, 15), 0, 0), isFalse);
    expect(isSolarDaylight(DateTime.utc(2026, 6, 21, 0), 80, 0), isTrue);
    expect(isSolarDaylight(DateTime.utc(2026, 12, 21, 12), 80, 0), isFalse);
    expect(isSolarDaylight(DateTime.utc(2026, 12, 21, 0), -80, 0), isTrue);
    expect(isSolarDaylight(DateTime.utc(2026, 6, 21, 12), -80, 0), isFalse);
    final utc = DateTime.utc(2024, 2, 29, 0);
    expect(isSolarDaylight(utc, 0, 179), isTrue);
    expect(isSolarDaylight(utc, 0, -179), isTrue);
    expect(isSolarDaylight(utc.toLocal(), 0, 179), isTrue);
    expect(isSolarDaylight(utc, double.nan, 0), isFalse);
  });
}
