// Unit tests for the Settings screen
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/screens/settings_screen.dart';
import 'package:flutter_driving_app/widgets/driving_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const saveError = 'Could not save your driving mode. Please try again.';

  late Map<String, String> storedValues;
  late bool failWrites;
  late int writeCount;
  Completer<void>? pendingWrite;

  setUp(() {
    storedValues = {'driving_mode': 'regular'};
    failWrites = false;
    writeCount = 0;
    pendingWrite = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storageChannel, (
      call,
    ) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          return storedValues[key];
        case 'write':
          writeCount++;
          await pendingWrite?.future;
          if (failWrites) {
            throw PlatformException(code: 'write_failed');
          }
          storedValues[key] = arguments['value'] as String;
          return null;
        default:
          throw StateError('Unexpected storage method: ${call.method}');
      }
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storageChannel,
      null,
    );
  });

  for (final initialMode in DrivingMode.values) {
    testWidgets(
      'failed save keeps ${initialMode.apiValue} selected and allows a retry',
      (tester) async {
        storedValues['driving_mode'] = initialMode.apiValue;
        failWrites = true;
        final initiallyNavigation = initialMode == DrivingMode.navigation;

        await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          initiallyNavigation,
        );

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();

        final switchAfterFailure = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        expect(tester.takeException(), isNull);
        expect(switchAfterFailure.value, initiallyNavigation);
        expect(switchAfterFailure.onChanged, isNotNull);
        expect(find.text(saveError), findsOneWidget);
        expect(storedValues['driving_mode'], initialMode.apiValue);
        expect(await tester.runAsync(loadDrivingMode), initialMode);

        failWrites = false;
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();

        final savedMode = initiallyNavigation
            ? DrivingMode.normal
            : DrivingMode.navigation;
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          !initiallyNavigation,
        );
        expect(await tester.runAsync(loadDrivingMode), savedMode);
        expect(find.text(saveError), findsNothing);
        expect(writeCount, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('pending save disables changes until persistence succeeds', (
    tester,
  ) async {
    pendingWrite = Completer<void>();
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final savingSwitch = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(savingSwitch.onChanged, isNull);
    expect(savingSwitch.value, isFalse);
    expect(find.text('Saving driving mode...'), findsOneWidget);
    expect(await tester.runAsync(loadDrivingMode), DrivingMode.normal);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(writeCount, 1);

    pendingWrite!.complete();
    await tester.pumpAndSettle();

    final savedSwitch = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(savedSwitch.value, isTrue);
    expect(savedSwitch.onChanged, isNotNull);
    expect(await tester.runAsync(loadDrivingMode), DrivingMode.navigation);
    expect(find.text('Saving driving mode...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final saveFails in [false, true]) {
    testWidgets('save completion after leaving is safe, failure=$saveFails', (
      tester,
    ) async {
      pendingWrite = Completer<void>();
      failWrites = saveFails;
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      pendingWrite!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        storedValues['driving_mode'],
        saveFails ? 'regular' : 'navigation',
      );
    });
  }
}
