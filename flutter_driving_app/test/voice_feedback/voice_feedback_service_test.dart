// Tests Live Voice Feedback rate limiting, queueing, on/off control, Stop
// Trip, background policy and error handling, using a fake detector, a fake
// speech output and a hand-advanced clock.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_alerts.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_feedback_service.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_output.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDetector implements VoiceAlertDetector {
  final List<VoiceAlert> next = [];

  @override
  DrivingMode get drivingMode => DrivingMode.normal;

  @override
  List<VoiceAlert> detectNewAlerts() {
    final alerts = List.of(next);
    next.clear();
    return alerts;
  }
}

enum _Failure { none, sync, async }

class _FakeOutput implements VoiceOutput {
  final List<String> spoken = [];
  final List<Completer<void>> _phrases = [];
  int stopCalls = 0;
  _Failure failure = _Failure.none;

  @override
  Future<void> speak(String text) {
    if (failure == _Failure.sync) throw StateError('engine crashed');
    spoken.add(text);
    if (failure == _Failure.async) return Future.error(StateError('no voice'));
    final phrase = Completer<void>();
    _phrases.add(phrase);
    return phrase.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  void finishPhrase() => _phrases.removeAt(0).complete();
}

void main() {
  final start = DateTime.utc(2026, 10, 22, 10);
  late DateTime now;
  late _FakeDetector detector;
  late _FakeOutput output;
  late VoiceFeedbackService voice;
  late bool foreground;

  VoiceFeedbackService build({
    bool enabled = true,
    bool speaksInBackground = true,
  }) => VoiceFeedbackService(
    detector: detector,
    output: output,
    clock: () => now,
    enabled: enabled,
    isAppInForeground: () => foreground,
    speaksInBackground: speaksInBackground,
  );

  setUp(() {
    now = start;
    foreground = true;
    detector = _FakeDetector();
    output = _FakeOutput();
    voice = build();
  });

  void at(double seconds) =>
      now = start.add(Duration(milliseconds: (seconds * 1000).round()));

  // Advances the clock, reports any onsets, then runs one check
  void check(double seconds, [List<VoiceAlert> alerts = const []]) {
    at(seconds);
    detector.next.addAll(alerts);
    voice.check();
  }

  // Lets completion callbacks from the fake output run
  Future<void> finishPhrase(double seconds) async {
    at(seconds);
    output.finishPhrase();
    await Future<void>.delayed(Duration.zero);
  }

  final speeding = VoiceAlert.speeding.phrase;
  final following = VoiceAlert.followingDistance.phrase;
  final braking = VoiceAlert.harshBraking.phrase;
  final focus = VoiceAlert.focus.phrase;

  test('speaks an onset once and stays quiet without a new one', () async {
    check(0, [VoiceAlert.speeding]);
    expect(output.spoken, [speeding]);
    await finishPhrase(2);
    for (var second = 3; second <= 60; second++) {
      check(second.toDouble());
    }
    expect(output.spoken, [speeding]);
  });

  test('the same alert is ignored during its cooldown', () async {
    check(0, [VoiceAlert.speeding]);
    await finishPhrase(2);
    check(29, [VoiceAlert.speeding]);
    check(30);
    expect(output.spoken, [speeding]);
    check(31, [VoiceAlert.speeding]);
    expect(output.spoken, [speeding, speeding]);
  });

  test('cooldowns are per alert', () async {
    check(0, [VoiceAlert.harshBraking]);
    await finishPhrase(1);
    check(5, [VoiceAlert.harshTurning]);
    expect(output.spoken, [braking, VoiceAlert.harshTurning.phrase]);
  });

  test('waits the minimum gap after the previous phrase ends', () async {
    check(0, [VoiceAlert.speeding]);
    await finishPhrase(2);
    check(3, [VoiceAlert.harshBraking]);
    expect(output.spoken, [speeding]);
    check(3.9);
    expect(output.spoken, [speeding]);
    check(4);
    expect(output.spoken, [speeding, braking]);
  });

  test('never overlaps: a new alert waits for the current phrase', () async {
    check(0, [VoiceAlert.speeding]);
    check(1, [VoiceAlert.harshBraking]);
    check(2);
    expect(output.spoken, [speeding]);
    await finishPhrase(2.5);
    check(3);
    expect(output.spoken, [speeding]);
    check(4.5);
    expect(output.spoken, [speeding, braking]);
  });

  test('holds one waiting alert and prefers the more urgent one', () async {
    check(0, [VoiceAlert.focus]);
    check(0.5, [VoiceAlert.harshBraking]);
    check(1, [VoiceAlert.followingDistance]);
    check(1.5, [VoiceAlert.speeding]);
    await finishPhrase(2);
    check(4);
    check(5);
    await finishPhrase(6);
    for (var second = 7; second <= 20; second++) {
      check(second.toDouble());
    }
    expect(output.spoken, [focus, following]);
  });

  test('alerts detected together are spoken most urgent first', () async {
    check(0, [VoiceAlert.followingDistance, VoiceAlert.speeding]);
    expect(output.spoken, [following]);
  });

  test('drops a waiting alert once it is stale', () async {
    check(0, [VoiceAlert.speeding]);
    check(1, [VoiceAlert.harshBraking]);
    await finishPhrase(6);
    check(8);
    expect(output.spoken, [speeding]);
    for (var second = 9; second <= 20; second++) {
      check(second.toDouble());
    }
    expect(output.spoken, [speeding]);
  });

  test('a phrase that never reports completion is timed out', () {
    check(0, [VoiceAlert.speeding]);
    check(3, [VoiceAlert.harshBraking]);
    check(8);
    expect(output.spoken, [speeding]);
    // The watchdog ends the first phrase at 8.1 s; the braking alert
    // (detected at 3 s) is stale by the time the gap has passed.
    check(8.1);
    check(10);
    expect(output.spoken, [speeding]);
    check(10.2, [VoiceAlert.harshTurning]);
    expect(output.spoken, [speeding, VoiceAlert.harshTurning.phrase]);
  });

  test('a late completion of a timed-out phrase is ignored', () async {
    check(0, [VoiceAlert.speeding]);
    check(8.1);
    check(10.1, [VoiceAlert.harshBraking]);
    expect(output.spoken, [speeding, braking]);
    await finishPhrase(11);
    check(11.5, [VoiceAlert.harshTurning]);
    check(12);
    // The braking phrase is still playing; the turning alert must wait.
    expect(output.spoken, [speeding, braking]);
  });

  group('on/off', () {
    test('turning off stops speech and drops the waiting alert', () async {
      check(0, [VoiceAlert.speeding]);
      check(1, [VoiceAlert.harshBraking]);
      voice.enabled = false;
      expect(voice.enabled, isFalse);
      expect(output.stopCalls, 1);
      voice.enabled = true;
      for (var second = 2; second <= 10; second++) {
        check(second.toDouble());
      }
      expect(output.spoken, [speeding]);
    });

    test('alerts while off are not replayed when turned back on', () {
      voice.enabled = false;
      check(0, [VoiceAlert.speeding]);
      check(1, [VoiceAlert.harshBraking]);
      voice.enabled = true;
      for (var second = 2; second <= 10; second++) {
        check(second.toDouble());
      }
      expect(output.spoken, isEmpty);
      check(11, [VoiceAlert.harshTurning]);
      expect(output.spoken, [VoiceAlert.harshTurning.phrase]);
    });

    test('a new phrase can start right after turning back on', () {
      check(0, [VoiceAlert.speeding]);
      voice.enabled = false;
      voice.enabled = true;
      check(2.5, [VoiceAlert.harshBraking]);
      expect(output.spoken, [speeding, braking]);
    });

    test('starting disabled stays silent until turned on', () {
      voice = build(enabled: false);
      expect(voice.enabled, isFalse);
      check(0, [VoiceAlert.speeding]);
      expect(output.spoken, isEmpty);
      voice.enabled = true;
      check(1, [VoiceAlert.harshBraking]);
      expect(output.spoken, [braking]);
    });
  });

  test('stop is final and ignores late completions', () async {
    check(0, [VoiceAlert.speeding]);
    voice.stop();
    expect(output.stopCalls, 1);
    await finishPhrase(1);
    voice.enabled = false;
    voice.enabled = true;
    voice.stop();
    for (var second = 2; second <= 60; second++) {
      check(second.toDouble(), [VoiceAlert.values[second % 6]]);
    }
    expect(output.spoken, [speeding]);
    expect(output.stopCalls, 1);
  });

  test('speech errors are contained and later alerts still play', () async {
    output.failure = _Failure.sync;
    check(0, [VoiceAlert.speeding]);
    expect(output.spoken, isEmpty);
    output.failure = _Failure.async;
    check(2, [VoiceAlert.harshBraking]);
    await Future<void>.delayed(Duration.zero);
    output.failure = _Failure.none;
    check(4, [VoiceAlert.harshTurning]);
    expect(output.spoken, [braking, VoiceAlert.harshTurning.phrase]);
  });

  group('background', () {
    test('speaks while backgrounded when allowed (Android)', () {
      foreground = false;
      check(0, [VoiceAlert.speeding]);
      expect(output.spoken, [speeding]);
    });

    test('foreground-only platforms drop background alerts', () async {
      voice = build(speaksInBackground: false);
      check(0, [VoiceAlert.speeding]);
      foreground = false;
      check(1, [VoiceAlert.harshBraking]);
      expect(output.stopCalls, 1);
      check(2, [VoiceAlert.harshTurning]);
      foreground = true;
      for (var second = 3; second <= 10; second++) {
        check(second.toDouble());
      }
      expect(output.spoken, [speeding]);
      check(11, [VoiceAlert.focus]);
      expect(output.spoken, [speeding, focus]);
    });

    test('the default policy speaks in the background only on Android', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final (platform, speaks) in [
        (TargetPlatform.android, true),
        (TargetPlatform.iOS, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        output = _FakeOutput();
        voice = VoiceFeedbackService(
          detector: detector,
          output: output,
          clock: () => now,
          isAppInForeground: () => false,
        );
        check(0, [VoiceAlert.speeding]);
        expect(output.spoken, speaks ? [speeding] : isEmpty);
      }
    });
  });
}
