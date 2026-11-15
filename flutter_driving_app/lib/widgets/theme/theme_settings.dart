// Persists theme preferences and shares manual or daylight-based theme selection.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'solar_daylight.dart';

final themeSettings = ThemeSettings();

/// The same persisted theme preference drives Settings and the live dashboard.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const storageKey = 'app_theme';
  static const _storage = FlutterSecureStorage();
  final DateTime Function() _clock;
  bool _autoSwitch = false;
  bool _manualDark = true;
  bool _daylight = false;
  bool _isSaving = false;
  double? _latitude;
  double? _longitude;

  bool get autoSwitch => _autoSwitch;
  bool get isSaving => _isSaving;
  bool get waitingForLocation => _autoSwitch && _latitude == null;
  bool get isDark => _autoSwitch ? !_daylight : _manualDark;
  ThemeMode get themeMode => isDark ? ThemeMode.dark : ThemeMode.light;

  Future<void> load() async {
    final stored = await _storage.read(key: storageKey);
    var autoSwitch = false;
    var manualDark = true;
    if (stored != null) {
      try {
        final data = jsonDecode(stored);
        if (data is Map<String, dynamic>) {
          autoSwitch = data['autoSwitch'] == true;
          manualDark = data['manualDark'] != false;
        }
      } on FormatException {
        // A damaged/legacy preference falls back to the first-launch defaults.
      }
    }
    _autoSwitch = autoSwitch;
    _manualDark = manualDark;
    refreshDaylight();
    notifyListeners();
  }

  Future<void> setAutoSwitch(bool enabled) async {
    if (_isSaving || enabled == _autoSwitch) return;
    await _save(autoSwitch: enabled, manualDark: _manualDark);
  }

  Future<void> setDark(bool dark) async {
    if (_isSaving || _autoSwitch || dark == _manualDark) return;
    await _save(autoSwitch: false, manualDark: dark);
  }

  Future<void> _save({
    required bool autoSwitch,
    required bool manualDark,
  }) async {
    _isSaving = true;
    notifyListeners();
    try {
      // Store both fields together; only apply a change after a successful save.
      await _storage.write(
        key: storageKey,
        value: jsonEncode({'autoSwitch': autoSwitch, 'manualDark': manualDark}),
      );
      _autoSwitch = autoSwitch;
      _manualDark = manualDark;
      refreshDaylight();
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  void updateLocation(double latitude, double longitude) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      return;
    }
    final wasWaiting = waitingForLocation;
    _latitude = latitude;
    _longitude = longitude;
    refreshDaylight();
    if (wasWaiting) notifyListeners();
  }

  void refreshDaylight() {
    if (_latitude == null || _longitude == null) return;
    final daylight = isSolarDaylight(_clock(), _latitude!, _longitude!);
    if (_daylight == daylight) return;
    _daylight = daylight;
    if (_autoSwitch) notifyListeners();
  }
}
