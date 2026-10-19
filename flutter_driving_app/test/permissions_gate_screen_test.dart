// Tests precise-location recovery and permission-request failures on Android and iOS.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/screens/permissions_gate_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class _Location extends GeolocatorPlatform {
  int temporaryRequests = 0;
  bool failTemporaryRequest = false;

  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() async =>
      LocationAccuracyStatus.reduced;

  @override
  Future<LocationAccuracyStatus> requestTemporaryFullAccuracy({
    required String purposeKey,
  }) async {
    temporaryRequests++;
    if (failTemporaryRequest) throw StateError('Request failed');
    return LocationAccuracyStatus.reduced;
  }
}

Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() check,
) async {
  final previous = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = platform;
  try {
    await check();
  } finally {
    debugDefaultTargetPlatformOverride = previous;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late GeolocatorPlatform originalLocation;
  late _Location location;
  var failRequests = false;
  var requestCount = 0;

  setUp(() {
    originalLocation = GeolocatorPlatform.instance;
    location = _Location();
    GeolocatorPlatform.instance = location;
    failRequests = false;
    requestCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          switch (call.method) {
            case 'checkPermissionStatus':
              return 0;
            case 'requestPermissions':
              requestCount++;
              if (failRequests) throw PlatformException(code: 'request_failed');
              return {for (final value in call.arguments as List) value: 1};
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    GeolocatorPlatform.instance = originalLocation;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });

  testWidgets(
    'Android approximate location offers Settings without an iOS request',
    (tester) => _onPlatform(TargetPlatform.android, () async {
      await tester.pumpWidget(const MaterialApp(home: PermissionsGateScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grant permissions'));
      await tester.pumpAndSettle();
      expect(location.temporaryRequests, 0);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'a permission failure clears the busy state and allows retry',
    (tester) => _onPlatform(TargetPlatform.android, () async {
      failRequests = true;
      await tester.pumpWidget(const MaterialApp(home: PermissionsGateScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grant permissions'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not update permissions. Please try again.'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(requestCount, 1);
      failRequests = false;
      await tester.tap(find.text('Grant permissions'));
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
      expect(requestCount, greaterThan(1));
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'iOS temporary-accuracy failure still reaches Settings recovery',
    (tester) => _onPlatform(TargetPlatform.iOS, () async {
      location.failTemporaryRequest = true;
      await tester.pumpWidget(const MaterialApp(home: PermissionsGateScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grant permissions'));
      await tester.pumpAndSettle();
      expect(location.temporaryRequests, 1);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    }),
  );
}
