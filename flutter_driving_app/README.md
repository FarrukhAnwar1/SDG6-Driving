# flutter_driving_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Android location plugin workaround

`geolocator_android` is pinned to **4.5.5**, including a dependency override
because `geolocator` 13 otherwise requires Android plugin 4.6.0 or newer.
The Android API used by this app is compatible with the pinned version.

The newer plugin always registers NMEA/GNSS listeners. Cancelling a location
stream can block Android's main thread in `NmeaClient.stop()` /
`unregisterGnssNmeaCallback`, freezing GPS delivery and the UI when starting or
stopping a trip. This was confirmed in the emulator's Android ANR trace and
matches [upstream issue #1795](https://github.com/Baseflow/flutter-geolocator/issues/1795).

This app does not use mean-sea-level altitude. With 4.5.5 and
`useMSLAltitude: false`, those unused listeners are never registered or removed.
GPS coordinates, speed, foreground tracking, and trip interval changes remain
available. Keep the pin and override together until a verified upstream fix
can replace the workaround.

After changing this native dependency, run `flutter pub get` and fully stop and
rebuild the app. Hot reload cannot replace the Android plugin. If the emulator
is already frozen, cold boot it before retesting a mock route and Stop Trip.
