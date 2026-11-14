# Live Voice Feedback

During a trip, the Live Dashboard speaks a short, plain-language alert when the
driver does something that starts costing grade points. This frontend work
covers detection, rate limiting and speech on the dashboard. Settings and the
dashboard speaker icon share a saved on/off preference; see
[Toggle hook-up](#toggle-hook-up).
Warnings before points are lost (for example during grace windows), visual or
haptic alerts, and backend changes are not part of this feature. Voice feedback
never changes grades, violations, `TripSummary`, reports, uploads or analytics.

## Alerts

| Alert | Modes | Spoken when | Cooldown | Phrase |
| --- | --- | --- | --- | --- |
| Following distance | Regular, Navigation | First frame charged after the 5 s grace (25 mph or more, under 1.5 s headway) | 30 s | "Too close. Increase your following distance." |
| Speeding | All | First GPS fix charged after more than 5 s at or over the threshold | 30 s | "Slow down, you're over the speed limit." |
| Harsh braking | All | A braking spike is confirmed (350 ms at 0.5 g or more) | 15 s | "Brake more gently." |
| Harsh turning | All | A turning spike is confirmed | 15 s | "Take turns more slowly." |
| Harsh accelerating | All | An accelerating spike is confirmed | 15 s | "Accelerate more gently." |
| Focus | Regular | The driver returns to the app after at least 1 s away while moving | 15 s | "Stay in the app while driving." |

The table is in priority order. Alerts still play once a category's grade is 0.
Focus points only come off when the app returns to the foreground, so its
alert can only play then. Early in a trip only turning can fire for smoothness,
because braking and accelerating wait for forward-axis calibration.

Onsets come from read-only grader signals, never from grade changes:
`SpeedGradingService.isPenalizing` and
`FollowingDistanceMonitoringService.isPenalizing` (false to true),
`SmoothnessGradingService.violationCountFor` and
`FocusedDrivingGradingService.violationCount` (count increases). A smoothness
spike that merges into the previous violation does not raise the count and is
not re-announced.

## Rate limiting

- **One alert per episode**, with no repeating reminders. After an onset is
  accepted, the same alert is ignored for its cooldown, even if it was not
  spoken (stale or backgrounded on iOS/web). Onsets while feedback is disabled
  are tracked and discarded without starting or extending a cooldown. Existing
  cooldowns from enabled alerts remain in effect when feedback is toggled.
  Cooldowns are longer than the graders' merge windows (10 s speed, 5 s
  smoothness) because merged speeding streaks, GPS gaps, speed-limit refreshes
  and flapping camera detection can each restart grace.
- **Never overlapping.** A phrase is never interrupted by another alert. At most
  one alert waits; a more urgent one replaces it. It plays 2 s after the
  previous phrase ends (`minGapBetweenAlerts`) or is dropped once older than
  6 s (`maxAlertAge`). Expired alerts are removed before comparing new onsets
  by priority.
- If the speech engine never reports the end of a phrase, it is treated as
  ended after 8 s (`maxUtteranceDuration`).

All timing uses the dashboard's injected clock and is evaluated in
`VoiceFeedbackService.check()`, which the dashboard calls synchronously from its
sensor, GPS, camera, lifecycle and one-second timer callbacks. Nothing awaits
speech and no timers are created.

## Audio and platforms

Speech uses pinned `flutter_tts` 4.2.5 with a fixed `en-US` voice and default
rate and volume.

- **Android:** navigation-guidance audio attributes, and each phrase requests
  transient "may duck" audio focus, so Google Maps guidance or music is lowered
  rather than paused. Speech continues while the app is backgrounded during a
  trip (the location foreground service keeps the trip running), for example
  over Google Maps in Navigation mode. The manifest declares the
  `android.intent.action.TTS_SERVICE` query required on Android 11+. No new
  permissions.
- **iOS:** playback category with `duckOthers`; the plugin releases ducking
  when a phrase finishes. Foreground only: background speech would need the
  `audio` background mode, which is not enabled.
- **Web:** browser speech synthesis, foreground only, without audio focus.

Failures (no TTS engine, no `en-US` voice, platform errors) are logged with
`debugPrint` and voice feedback continues silently. They never affect grading,
the dashboard or Stop Trip.

Stop Trip silences voice feedback before the graders are finalized, so closing
out a trailing violation cannot trigger an alert. Dispose does the same.
Stopping also cancels speech still waiting for the TTS engine to initialize.

Known limitations: on Android an engine error can leave other audio ducked
until the next phrase finishes, and on iOS stopping a phrase early (turning
feedback off mid-phrase) does not release ducking. Another app's voice (such as
Maps guidance) can still speak at the same time as an alert.

## Toggle hook-up

`voice_feedback_settings.dart` owns the shared `voiceFeedbackSettings` notifier.
It loads `live_voice_feedback` from `FlutterSecureStorage` before the app opens
and when Settings loads. A missing preference defaults to enabled. Both toggles
call `setEnabled`, which saves before publishing the new value. While saving,
both controls are disabled; failures retain the current value and show a retry
message. If startup cannot read storage, it logs the error and keeps the default;
Settings can retry loading.

The dashboard initializes its voice service from this notifier and listens for
changes throughout the trip. Turning feedback off stops speech and drops any
waiting alert. Turning it on resumes with the next new alert: missed alerts are
never replayed and an episode already in progress is not announced. After Stop
Trip or dispose the voice service's setter has no effect.

## Code and verification

Code lives in `lib/widgets/voice_feedback/`: `voice_alerts.dart` (alerts,
phrases, priorities, cooldowns, onset detection), `voice_feedback_service.dart`
(rate limiting, on/off, background policy) and `voice_output.dart` (the
`VoiceOutput` interface and the `flutter_tts` implementation). The dashboard
accepts an optional `voiceOutput` so tests can record phrases.

Run `flutter analyze` and `flutter test`. Tests in `test/voice_feedback/` cover
onset detection against the real graders, rate limiting, queueing, on/off,
Stop Trip, background policy and error handling with a fake output and clock,
and simulated dashboard drives for speeding, following distance and focus.
`voice_output_test.dart` controls the TTS platform channel to cover startup
cancellation and completion callbacks. Run
`flutter test --platform chrome test/voice_feedback/voice_output_test.dart`
to also check the web plugin's null acknowledgement, which must wait for a
completion callback before the next alert can play.
`test/grading/speed_grading_is_penalizing_test.dart` and
`test/following_distance/following_distance_is_penalizing_test.dart` cover the
read-only signals. Widget tests that don't inject an output use the real one;
its platform calls never answer in tests, and the 8 s watchdog keeps that
harmless.

`flutter build apk --debug --target-platform android-arm64` and
`flutter build web --debug` check platform integration. Fakes don't prove what
a phone actually sounds like; on a device, check a speeding alert on an
emulator mock route, smoothness alerts on a real drive, ducking with Google
Maps audio playing in Navigation mode, and silence without errors on a device
with no TTS engine.
