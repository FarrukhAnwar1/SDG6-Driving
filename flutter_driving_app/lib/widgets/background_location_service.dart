// Handles continuous background location tracking broadcasting
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class BackgroundLocationService {
  BackgroundLocationService._();

  // Idle interval to save battery
  static const Duration _idleUpdateInterval = Duration(seconds: 10);
  static const int _idleDistanceFilterMeters = 10;

  // Quicker trip interval
  static const Duration _tripUpdateInterval = Duration(seconds: 1);
  static const int _tripDistanceFilterMeters = 0;

  static const LocationAccuracy _accuracy = LocationAccuracy.high;

  static StreamSubscription<Position>? _subscription;
  static bool _tripModeActive = false;

  // Google Play Services' Fused Location Provider (FLP) is what we try
  // first on Android.It fuses GPS with sensor/network data and populates
  // `Position.speedAccuracy`, which the dashboard uses to decide when to
  // trust reported speed. But FLP leans on the device's network-assisted
  // location layer, and some users disable "Google Location Accuracy" in
  // system settings, which can leave FLP never producing an update at all. If
  // that happens we fall back to the raw LocationManager (GPS only), which
  // works regardless of that setting, at the cost of losing speedAccuracy.
  static bool _forceLocationManagerFallback = false;
  static bool _everReceivedPosition = false;
  static Timer? _fallbackWatchdog;
  static const Duration _fallbackTimeout = Duration(seconds: 10);

  // start(), stop(), enterTripMode(), and exitTripMode() all cancel and/or
  // replace `_subscription`. Routing every one of them through this queue
  // makes sure only one such operation runs at a time.
  static Future<void> _operationQueue = Future<void>.value();

  static Future<void> _enqueue(Future<void> Function() operation) {
    final result = _operationQueue.then((_) => operation());
    _operationQueue = result.catchError((_) {});
    return result;
  }

  // Broadcast position to necessary listeners
  static final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  static Stream<Position> get positionStream => _positionController.stream;

  static Position? _lastPosition;
  static Position? get lastPosition => _lastPosition;

  static bool get isTracking => _subscription != null;

  static Future<void> start() => _enqueue(_start);

  static Future<void> _start() async {
    if (_subscription != null) return;
    _subscription = _subscribe();
    _armFallbackWatchdog();
  }

  static Future<void> stop() => _enqueue(_stop);

  static Future<void> _stop() async {
    _fallbackWatchdog?.cancel();
    final sub = _subscription;
    _subscription = null;
    await sub?.cancel();
  }

  // Switches to the quicker trip interval
  static Future<void> enterTripMode() => _enqueue(() => _setTripMode(true));

  // Switches to slower idle interval
  static Future<void> exitTripMode() => _enqueue(() => _setTripMode(false));

  static Future<void> _setTripMode(bool active) async {
    if (_tripModeActive == active) return;
    _tripModeActive = active;

    final sub = _subscription;
    if (sub == null) return;

    _subscription = null;
    await sub.cancel();

    // Restart the underlying GPS subscription with the new settings
    _subscription = _subscribe();
    _armFallbackWatchdog();
  }

  static StreamSubscription<Position> _subscribe() {
    return Geolocator.getPositionStream(
      locationSettings: _currentSettings(),
    ).listen(
      _handlePosition,
      onError: (Object e) {
        debugPrint('BACKGROUND LOCATION ERROR: $e');
      },
    );
  }

  // If we're still waiting on a first-ever update and haven't already fallen
  // back, start (or restart) a timer that switches to the raw
  // LocationManager if FLP hasn't produced anything by the time it fires.
  static void _armFallbackWatchdog() {
    if (_everReceivedPosition || _forceLocationManagerFallback) return;

    _fallbackWatchdog?.cancel();
    _fallbackWatchdog = Timer(_fallbackTimeout, () {
      _enqueue(() async {
        if (_everReceivedPosition || _forceLocationManagerFallback) return;
        if (_subscription == null) return;

        debugPrint(
          'BACKGROUND LOCATION: no update from the Fused Location Provider '
          'after ${_fallbackTimeout.inSeconds}s -- falling back to '
          'LocationManager (the user likely has "Google Location Accuracy" '
          'disabled). Reported speed accuracy will be unavailable for this '
          'session; the dashboard will rely entirely on its manual '
          'speed = distance/time calculation instead.',
        );

        _forceLocationManagerFallback = true;

        final sub = _subscription;
        _subscription = null;
        await sub?.cancel();
        _subscription = _subscribe();
      });
    });
  }

  static LocationSettings _currentSettings() {
    final interval = _tripModeActive
        ? _tripUpdateInterval
        : _idleUpdateInterval;
    final distanceFilter = _tripModeActive
        ? _tripDistanceFilterMeters
        : _idleDistanceFilterMeters;

    return Platform.isAndroid
        ? AndroidSettings(
            accuracy: _accuracy,
            distanceFilter: distanceFilter,
            intervalDuration: interval,
            forceLocationManager: _forceLocationManagerFallback,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Location tracking is on',
              notificationText: 'Tap to return to the app.',
              enableWakeLock: true,
            ),
          )
        : AppleSettings(
            accuracy: _accuracy,
            distanceFilter: distanceFilter,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          );
  }

  static void _handlePosition(Position position) {
    debugPrint(
      'LOCATION UPDATE: ${position.latitude}, ${position.longitude} '
      '(+/-${position.accuracy}m)',
    );

    _everReceivedPosition = true;
    _fallbackWatchdog?.cancel();

    _lastPosition = position;
    _positionController.add(position);
  }
}
