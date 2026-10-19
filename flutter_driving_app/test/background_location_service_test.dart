// Exercises location restarts through the Android plugin's real Dart stream.
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/widgets/background_location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'flutter.baseflow.com/geolocator_updates_android';
  const channel = MethodChannel(channelName);
  late GeolocatorPlatform original;
  late List<String> calls;

  setUp(() {
    original = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = GeolocatorAndroid();
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() async {
    await BackgroundLocationService.stop();
    await BackgroundLocationService.exitTripMode();
    GeolocatorPlatform.instance = original;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> sendPosition(int second) async {
    binding.channelBuffers.push(
      channelName,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'latitude': 40.0 + second / 10000,
        'longitude': -75.0,
        'timestamp':
            DateTime.utc(2026, 10, 19).millisecondsSinceEpoch + second * 1000,
        'accuracy': 5.0,
        'altitude': 0.0,
        'altitude_accuracy': 1.0,
        'heading': 0.0,
        'heading_accuracy': 1.0,
        'speed': 10.0,
        'speed_accuracy': 0.1,
        'is_mocked': true,
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'Android GPS continues after switching into and out of trip mode',
    () async {
      final received = <Position>[];
      final listener = BackgroundLocationService.positionStream.listen(
        received.add,
      );
      try {
        await BackgroundLocationService.start();
        await sendPosition(0);
        await BackgroundLocationService.enterTripMode();
        await sendPosition(1);
        await BackgroundLocationService.exitTripMode();
        await sendPosition(2);
        expect(received, hasLength(3));
        expect(calls, ['listen', 'cancel', 'listen', 'cancel', 'listen']);
      } finally {
        await listener.cancel();
      }
    },
  );
}
