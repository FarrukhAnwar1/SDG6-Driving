// Continuous background location tracking
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class BackgroundLocationService {
  BackgroundLocationService._();

  // Important Service modifiers
  static const Duration _speedUpdateInterval = Duration(seconds: 10);
  static const int _minimumMovementForUpdateMeters = 10;
  static const LocationAccuracy _accuracy = LocationAccuracy.high;

  static StreamSubscription<Position>? _subscription;

  static bool get isTracking => _subscription != null;

  static Future<void> start() async {
    if (_subscription != null) return; // already running

    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: _accuracy,
            distanceFilter: _minimumMovementForUpdateMeters,
            intervalDuration: _speedUpdateInterval,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Location tracking is on',
              notificationText: 'Tap to return to the app.',
              enableWakeLock: true,
            ),
          )
        : AppleSettings(
            accuracy: _accuracy,
            distanceFilter: _minimumMovementForUpdateMeters,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          );

    _subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          _handlePosition,
          onError: (Object e) {
            debugPrint('BACKGROUND LOCATION ERROR: $e');
          },
        );
  }

  static Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  static void _handlePosition(Position position) {
    debugPrint(
      'LOCATION UPDATE: ${position.latitude}, ${position.longitude} '
      '(+/-${position.accuracy}m)',
    );

    // TODO: implement what to do after speed update (like sending
    // position.latitude and position.longitude to server to get posted speed limit
    // and then comparing it to position.speed to see if the driver is speeding)
    // NOTE: position.speed is in meters per second, so multiply by 2.23694 to get MPH
    // NOTE: current speed capture and posted speed limit requests might need 2 separate intervals
    // (such as every 1 second for speed capture to give user real-time speed data
    // and every 10 seconds for posted speed limit requests to avoid overloading the server)
  }
}
