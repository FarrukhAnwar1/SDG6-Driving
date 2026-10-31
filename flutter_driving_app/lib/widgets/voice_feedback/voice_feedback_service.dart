// Live Voice Feedback: speaks a short alert when the driver starts losing
// grade points (see voice_alerts.dart for what counts as an onset).
//
// RATE LIMITING:
// - One alert per episode. After an onset is accepted, the same alert is
//   ignored for its cooldown (VoiceAlertDetails), even if it was never spoken
//   (feedback off, stale, or backgrounded on iOS/web).
// - Phrases never overlap and are never interrupted by another alert. At most
//   one alert waits; a more urgent one replaces it. A waiting alert is
//   spoken [minGapBetweenAlerts] after the previous phrase ends, or dropped
//   once it is older than [maxAlertAge].
// - If the engine never reports the end of a phrase, it is treated as ended
//   after [maxUtteranceDuration].
//
// ON/OFF:
// Turning feedback off stops speech immediately and drops the waiting alert.
// Turning it back on never replays missed alerts: onsets keep being tracked
// while off, so an episode already in progress is not announced.
//
// BACKGROUND:
// Android keeps speaking while the app is backgrounded during a trip (e.g.
// over Google Maps in Navigation mode). iOS and web only speak in the
// foreground; background speech on iOS would need the "audio" background mode.
//
// TIMING:
// All timing uses the injected clock and is evaluated in check(), which the
// dashboard calls from its sensor, GPS, camera, lifecycle and 1 s timer
// callbacks. No timers are created, and check() never waits on speech.
//
// Voice feedback only reads grader state. It never changes grades,
// violations, the dashboard UI, or Stop Trip.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'voice_alerts.dart';
import 'voice_output.dart';

class VoiceFeedbackService {
  VoiceFeedbackService({
    required this._detector,
    VoiceOutput? output,
    DateTime Function()? clock,
    this._enabled = true,
    bool Function()? isAppInForeground,
    bool? speaksInBackground,
  }) : _output = output ?? FlutterTtsVoiceOutput(),
       _clock = clock ?? DateTime.now,
       _isAppInForeground = isAppInForeground ?? _appIsResumed,
       _speaksInBackground =
           speaksInBackground ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  // Pause between two phrases so they don't run together.
  static const Duration minGapBetweenAlerts = Duration(seconds: 2);

  // A waiting alert older than this no longer describes what the driver is
  // doing. Leaves room for one phrase (about 2 s) plus the gap.
  static const Duration maxAlertAge = Duration(seconds: 6);

  // Every phrase is about 2 s; this only guards against a missing callback.
  static const Duration maxUtteranceDuration = Duration(seconds: 8);

  final VoiceAlertDetector _detector;
  final VoiceOutput _output;
  final DateTime Function() _clock;
  final bool Function() _isAppInForeground;
  final bool _speaksInBackground;

  bool _enabled;
  bool _stopped = false;
  final Map<VoiceAlert, DateTime> _lastAcceptedAt = {};
  ({VoiceAlert alert, DateTime detectedAt})? _pending;

  // Identifies the phrase being spoken, so a late completion of an earlier
  // (stopped or timed-out) phrase is ignored.
  int _utteranceId = 0;
  DateTime? _speakingSince;
  DateTime? _lastFinishedAt;

  bool get enabled => _enabled;

  // Toggle hook for the Live Voice Feedback setting. Safe to call anytime.
  set enabled(bool value) {
    if (_stopped || value == _enabled) return;
    _enabled = value;
    if (!value) _silence();
  }

  bool get _isSpeaking => _speakingSince != null;

  // Detects new onsets, applies rate limits, and starts the next phrase if
  // one is due. Synchronous and cheap enough to call at sensor rate.
  void check() {
    if (_stopped) return;
    final now = _clock();
    final alerts = _detector.detectNewAlerts();

    final speakingSince = _speakingSince;
    if (speakingSince != null &&
        now.difference(speakingSince) > maxUtteranceDuration) {
      debugPrint('VOICE FEEDBACK: no completion callback, continuing');
      _finishUtterance(_utteranceId);
    }

    final canSpeak = _enabled && (_speaksInBackground || _isAppInForeground());
    for (final alert in alerts) {
      final lastAccepted = _lastAcceptedAt[alert];
      if (lastAccepted != null &&
          now.difference(lastAccepted) < alert.cooldown) {
        continue;
      }
      _lastAcceptedAt[alert] = now;
      if (!canSpeak) continue;
      final pending = _pending;
      if (pending == null || alert.priority < pending.alert.priority) {
        _pending = (alert: alert, detectedAt: now);
      }
    }

    if (!canSpeak) {
      // Disabled alerts were never queued; on iOS/web, don't let anything
      // queued or playing carry on in the background.
      if (_pending != null || _isSpeaking) _silence();
      return;
    }

    final pending = _pending;
    if (pending == null) return;
    if (now.difference(pending.detectedAt) > maxAlertAge) {
      _pending = null;
      return;
    }
    final lastFinished = _lastFinishedAt;
    if (_isSpeaking ||
        (lastFinished != null &&
            now.difference(lastFinished) < minGapBetweenAlerts)) {
      return;
    }
    _pending = null;
    _speak(pending.alert, now);
  }

  // Permanently silences voice feedback; used on Stop Trip and dispose.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _silence();
  }

  void _speak(VoiceAlert alert, DateTime now) {
    final id = ++_utteranceId;
    _speakingSince = now;
    try {
      unawaited(
        _output
            .speak(alert.phrase)
            .catchError((Object e) => debugPrint('VOICE FEEDBACK ERROR: $e'))
            .whenComplete(() => _finishUtterance(id)),
      );
    } catch (e) {
      debugPrint('VOICE FEEDBACK ERROR: $e');
      _finishUtterance(id);
    }
  }

  void _finishUtterance(int id) {
    if (id != _utteranceId || !_isSpeaking) return;
    _speakingSince = null;
    _lastFinishedAt = _clock();
  }

  // Stops the current phrase and drops the waiting alert.
  void _silence() {
    _pending = null;
    if (_isSpeaking) {
      _finishUtterance(_utteranceId);
      _utteranceId++;
    }
    try {
      unawaited(
        _output.stop().catchError(
          (Object e) => debugPrint('VOICE FEEDBACK ERROR: $e'),
        ),
      );
    } catch (e) {
      debugPrint('VOICE FEEDBACK ERROR: $e');
    }
  }

  static bool _appIsResumed() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }
}
