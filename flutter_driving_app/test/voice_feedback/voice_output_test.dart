// Exercises the real TTS adapter with controlled platform acknowledgements,
// initialization delays, and completion callbacks. Also runs in a web browser.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/voice_feedback/voice_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  late List<MethodCall> calls;
  late FlutterTtsVoiceOutput output;
  Object? speakResult;
  String? delayedMethod;
  Completer<Object?>? delayedResult;

  Future<void> drain() => Future<void>.delayed(Duration.zero);

  Future<void> sendEvent(String method) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall(method, method == 'speak.onError' ? 'engine error' : null),
      ),
      (_) {},
    );
    await drain();
  }

  List<MethodCall> spoken() =>
      calls.where((call) => call.method == 'speak').toList();

  setUp(() {
    calls = [];
    output = FlutterTtsVoiceOutput();
    speakResult = 1;
    delayedMethod = null;
    delayedResult = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == delayedMethod) return delayedResult!.future;
      if (call.method == 'isLanguageAvailable') return true;
      if (call.method == 'speak') return speakResult;
      return 1;
    });
  });

  tearDown(() async {
    await output.stop();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform
      in kIsWeb
          ? [TargetPlatform.windows]
          : [TargetPlatform.android, TargetPlatform.iOS]) {
    final configurationMethods = [
      'isLanguageAvailable',
      'setLanguage',
      if (!kIsWeb && platform == TargetPlatform.android)
        'setAudioAttributesForNavigation',
    ];
    for (final method in configurationMethods) {
      test(
        'stop during $method on ${platform.name} cancels deferred speech',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          delayedMethod = method;
          delayedResult = Completer<Object?>();
          final cancelled = output.speak('Cancelled alert');
          await drain();
          expect(calls.last.method, method);

          await output.stop();
          delayedResult!.complete(method == 'isLanguageAvailable' ? true : 1);
          await drain();
          expect(spoken(), isEmpty);
          await cancelled;

          // Muting must not prevent a later alert after the user turns it on.
          final next = output.speak('New alert');
          await drain();
          expect(spoken(), hasLength(1));
          await sendEvent('speak.onComplete');
          await next;
        },
      );
    }
  }

  for (final event in ['speak.onComplete', 'speak.onCancel', 'speak.onError']) {
    test('accepted speech completes only after $event', () async {
      var finished = false;
      final speech = output.speak('Driving alert').then((_) => finished = true);
      await drain();
      expect(spoken(), hasLength(1));
      expect(finished, isFalse);

      await sendEvent(event);
      await speech;
      expect(finished, isTrue);
    });
  }

  test('web null acknowledgement waits for the completion callback', () async {
    speakResult = null;
    var finished = false;
    final speech = output.speak('Driving alert').then((_) => finished = true);
    await drain();
    expect(spoken(), hasLength(1));
    expect(finished, isFalse);

    await sendEvent('speak.onComplete');
    await speech;
    expect(finished, isTrue);
  }, skip: !kIsWeb);

  test('stop completes accepted speech without a platform callback', () async {
    final speech = output.speak('Driving alert');
    await drain();
    await output.stop();
    await speech;
    expect(calls.where((call) => call.method == 'stop'), hasLength(1));
  });

  for (final throwsError in [false, true]) {
    test('a stopped request\'s late ${throwsError ? 'error' : 'rejection'} '
        'cannot finish a new alert', () async {
      delayedMethod = 'speak';
      delayedResult = Completer<Object?>();
      final cancelled = output.speak('Cancelled alert');
      await drain();
      expect(spoken(), hasLength(1));
      await output.stop();

      delayedMethod = null;
      var finished = false;
      final next = output.speak('New alert').then((_) => finished = true);
      await drain();
      expect(spoken(), hasLength(2));
      if (throwsError) {
        delayedResult!.completeError(PlatformException(code: 'speak_failed'));
      } else {
        delayedResult!.complete(0);
      }
      await cancelled;
      await drain();
      expect(finished, isFalse);

      await sendEvent('speak.onComplete');
      await next;
    });
  }

  test('rejected speech completes and allows a later alert', () async {
    speakResult = 0;
    await output.speak('Rejected alert');

    speakResult = 1;
    var finished = false;
    final next = output.speak('New alert').then((_) => finished = true);
    await drain();
    expect(spoken(), hasLength(2));
    expect(finished, isFalse);
    await sendEvent('speak.onComplete');
    await next;
  });
}
