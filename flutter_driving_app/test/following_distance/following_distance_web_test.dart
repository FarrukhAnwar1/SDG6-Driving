// Checks browser startup and the fallback when native camera detection is unavailable.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/main.dart';
import 'package:flutter_driving_app/screens/login_screen.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_camera.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';

void main() {
  testWidgets(
    'browser camera placeholder updates the dashboard without native inference',
    (tester) async {
      var unavailable = 0;
      var measurements = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, updateParent) => FollowingDistanceCamera(
              onMeasurement: (_) => measurements++,
              onUnavailable: () => updateParent(() => unavailable++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(unavailable, 1);
      expect(measurements, 0);
      expect(find.byType(CameraPreview), findsNothing);
      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: !kIsWeb,
  );

  testWidgets(
    'browser app startup opens login with the mobile detector dependency present',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: !kIsWeb,
  );
}
