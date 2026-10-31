// Speaks Live Voice Feedback phrases through the platform text-to-speech
// engine (flutter_tts).
//
// AUDIO:
// - Android: navigation-guidance audio attributes, and each phrase requests
//   transient "may duck" audio focus, so Maps guidance or music is lowered
//   rather than paused, then restored when the phrase ends.
// - iOS: playback category with duckOthers, which the plugin releases after
//   each phrase finishes.
// - Web: the browser's speech synthesis, without audio focus control.
//
// FAILURES:
// No TTS engine, a missing en-US voice, or any platform error is logged with
// debugPrint and the output stays silent; speak never throws.
// MissingPluginException (widget tests, unsupported platforms) disables the
// output after logging once.
//
// COMPLETION:
// speak completes when the phrase finishes, is cancelled, or fails. It does
// not use awaitSpeakCompletion, which on Android never resolves after an
// engine error. If the engine never calls back at all (e.g. it failed to
// initialize), the future stays pending; VoiceFeedbackService has its own
// clock-based watchdog, so no timers are created here.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

abstract interface class VoiceOutput {
  // Completes when the phrase has finished, been stopped, or failed.
  Future<void> speak(String text);

  // Stops the current phrase immediately.
  Future<void> stop();
}

class FlutterTtsVoiceOutput implements VoiceOutput {
  static const String language = 'en-US';

  FlutterTts? _tts;
  Future<bool>? _ready;
  Completer<void>? _utterance;
  bool _unavailable = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<void> speak(String text) async {
    if (_unavailable) return;
    try {
      if (!await (_ready ??= _configure())) return;
      _finishUtterance();
      final utterance = _utterance = Completer<void>();
      // 1 means the engine accepted the phrase; it then reports completion,
      // cancellation, or an error through the handlers set in _configure.
      final result = await _tts!.speak(text, focus: _isAndroid);
      if (result != 1) {
        debugPrint('VOICE FEEDBACK ERROR: speak returned $result');
        _finishUtterance();
      }
      await utterance.future;
    } on MissingPluginException catch (e) {
      _disable(e);
    } catch (e) {
      debugPrint('VOICE FEEDBACK ERROR: $e');
      _finishUtterance();
    }
  }

  @override
  Future<void> stop() async {
    final tts = _tts;
    _finishUtterance();
    if (tts == null || _unavailable) return;
    try {
      await tts.stop();
    } on MissingPluginException catch (e) {
      _disable(e);
    } catch (e) {
      debugPrint('VOICE FEEDBACK ERROR: $e');
    }
  }

  // Creates the engine on first use, so screens that never speak (and tests
  // without the plugin) never touch it. Returns false if it cannot speak.
  Future<bool> _configure() async {
    final tts = _tts = FlutterTts();
    tts.setCompletionHandler(_finishUtterance);
    tts.setCancelHandler(_finishUtterance);
    tts.setErrorHandler((message) {
      debugPrint('VOICE FEEDBACK ERROR: $message');
      _finishUtterance();
    });

    if (await tts.isLanguageAvailable(language) != true) {
      debugPrint('VOICE FEEDBACK UNAVAILABLE: no $language voice');
      _unavailable = true;
      return false;
    }
    await tts.setLanguage(language);
    if (_isAndroid) {
      await tts.setAudioAttributesForNavigation();
    } else if (_isIos) {
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions
              .interruptSpokenAudioAndMixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
    }
    return true;
  }

  void _finishUtterance() {
    final utterance = _utterance;
    _utterance = null;
    if (utterance != null && !utterance.isCompleted) utterance.complete();
  }

  void _disable(MissingPluginException e) {
    if (!_unavailable) debugPrint('VOICE FEEDBACK UNAVAILABLE: $e');
    _unavailable = true;
    _finishUtterance();
  }
}
