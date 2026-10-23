# flutter_driving_app

See [Live following-distance grading](docs/following_distance.md) for the
camera baseline, grading thresholds, trip modes, summary/report handoff,
testing, and the separate backend/Settings integration work.

## Source and test layout

Widgets and supporting code are grouped one level below `lib/widgets/` by
feature. Related tests use the same feature folders under `test/`.

| Folder | Contents |
| --- | --- |
| `auth/` | Session handling, password validation, and authentication navigation. |
| `driving/` | Driving modes, location tracking, orientation calibration, and speed limits. |
| `driving_family/` | Family APIs, models, and forms. |
| `driving_reports/` | Trip results, report APIs, upload queues, and report policies. |
| `following_distance/` | Road camera, vehicle detection, distance estimation, and following-distance grading. |
| `grading/` | Speed, smoothness, focus, overall grades, and grade presentation. |
| `permissions/` | Required platform permissions. |
| `shared/` | API configuration and reusable error messages. |

Shared test data lives in `test/fixtures/`. Run all tests with `flutter test`, or
run one feature with, for example, `flutter test test/following_distance/`.

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
