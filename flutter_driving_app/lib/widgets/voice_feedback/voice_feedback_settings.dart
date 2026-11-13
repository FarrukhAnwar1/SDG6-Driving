// Persists the voice feedback preference shared by Settings and the dashboard.
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Both screens and the active trip share this persisted preference.
final voiceFeedbackSettings = VoiceFeedbackSettings();

class VoiceFeedbackSettings extends ValueNotifier<bool> {
  VoiceFeedbackSettings() : super(true);

  static const storageKey = 'live_voice_feedback';
  static const _storage = FlutterSecureStorage();
  bool _isSaving = false;
  bool get isSaving => _isSaving;

  Future<void> load() async {
    final stored = await _storage.read(key: storageKey);
    value = stored != 'false';
  }

  Future<void> setEnabled(bool enabled) async {
    if (_isSaving || enabled == value) return;
    _isSaving = true;
    notifyListeners();
    try {
      await _storage.write(key: storageKey, value: enabled.toString());
      value = enabled;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }
}
