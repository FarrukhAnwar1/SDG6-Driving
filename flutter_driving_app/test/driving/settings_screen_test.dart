// Unit tests for the Settings screen
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driving_app/screens/settings_screen.dart';
import 'package:flutter_driving_app/widgets/driving/driving_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The Settings page is taller than the default 800x600 test screen now that
  // it has three mode cards, so each widget test runs on a taller screen.
  void testSettings(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await body(tester);
    });
  }

  const selectableModes = DrivingMode.values;
  const cardTitles = {
    DrivingMode.normal: 'Regular Mode',
    DrivingMode.navigation: 'Navigation Mode',
    DrivingMode.pocket: 'Pocket Mode',
  };
  // A different mode to switch to from each starting mode
  const switchTargets = {
    DrivingMode.normal: DrivingMode.pocket,
    DrivingMode.navigation: DrivingMode.normal,
    DrivingMode.pocket: DrivingMode.navigation,
  };
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const saveError = 'Could not save your driving mode. Please try again.';
  const loadError = 'Could not load your settings. Please try again.';

  late Map<String, String> storedValues;
  late bool failReads;
  late bool failWrites;
  late int writeCount;
  Completer<void>? pendingRead;
  Completer<void>? pendingWrite;

  setUp(() {
    storedValues = {'driving_mode': 'regular'};
    failReads = false;
    failWrites = false;
    writeCount = 0;
    pendingRead = null;
    pendingWrite = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storageChannel, (
      call,
    ) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          await pendingRead?.future;
          if (failReads) {
            throw PlatformException(code: 'read_failed');
          }
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

  Finder modeCard(DrivingMode mode) => find.ancestor(
    of: find.text(cardTitles[mode]!),
    matching: find.byType(Card),
  );

  InkWell modeButton(WidgetTester tester, DrivingMode mode) =>
      tester.widget<InkWell>(
        find.descendant(of: modeCard(mode), matching: find.byType(InkWell)),
      );

  void expectSelected(DrivingMode mode) {
    for (final candidate in selectableModes) {
      expect(
        find.descendant(
          of: modeCard(candidate),
          matching: find.byIcon(Icons.check_circle),
        ),
        candidate == mode ? findsOneWidget : findsNothing,
      );
    }
  }

  testSettings('failed load shows retry and recovers the saved mode', (
    tester,
  ) async {
    storedValues['driving_mode'] = 'navigation';
    failReads = true;
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(loadError), findsOneWidget);
    for (final title in cardTitles.values) {
      expect(find.text(title), findsNothing);
    }
    expect(writeCount, 0);

    failReads = false;
    pendingRead = Completer<void>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(loadError), findsNothing);
    expect(find.text('Retry'), findsNothing);

    pendingRead!.complete();
    await tester.pumpAndSettle();
    expectSelected(DrivingMode.navigation);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(writeCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final loadFails in [false, true]) {
    testSettings('load completion after leaving is safe, failure=$loadFails', (
      tester,
    ) async {
      pendingRead = Completer<void>();
      failReads = loadFails;
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      pendingRead!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(writeCount, 0);
    });
  }

  for (final initialMode in selectableModes) {
    testSettings(
      'failed save keeps ${initialMode.apiValue} selected and allows a retry',
      (tester) async {
        storedValues['driving_mode'] = initialMode.apiValue;
        failWrites = true;
        final savedMode = switchTargets[initialMode]!;

        await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
        await tester.pumpAndSettle();
        expectSelected(initialMode);

        await tester.tap(modeCard(savedMode));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expectSelected(initialMode);
        expect(modeButton(tester, savedMode).onTap, isNotNull);
        expect(find.text(saveError), findsOneWidget);
        expect(storedValues['driving_mode'], initialMode.apiValue);
        expect(await tester.runAsync(loadDrivingMode), initialMode);

        failWrites = false;
        await tester.tap(modeCard(savedMode));
        await tester.pumpAndSettle();

        expectSelected(savedMode);
        expect(await tester.runAsync(loadDrivingMode), savedMode);
        expect(find.text(saveError), findsNothing);
        expect(writeCount, 2);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
        await tester.pumpAndSettle();
        expectSelected(savedMode);
        expect(writeCount, 2);
      },
    );
  }

  testSettings('pending save disables changes until persistence succeeds', (
    tester,
  ) async {
    pendingWrite = Completer<void>();
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(modeCard(DrivingMode.navigation));
    await tester.pumpAndSettle();

    for (final mode in selectableModes) {
      expect(modeButton(tester, mode).onTap, isNull);
    }
    expectSelected(DrivingMode.normal);
    expect(find.text('Saving driving mode...'), findsOneWidget);
    expect(await tester.runAsync(loadDrivingMode), DrivingMode.normal);

    await tester.tap(modeCard(DrivingMode.navigation));
    await tester.pump();
    expect(writeCount, 1);

    pendingWrite!.complete();
    await tester.pumpAndSettle();

    expectSelected(DrivingMode.navigation);
    for (final mode in selectableModes) {
      expect(modeButton(tester, mode).onTap, isNotNull);
    }
    expect(await tester.runAsync(loadDrivingMode), DrivingMode.navigation);
    expect(find.text('Saving driving mode...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final saveFails in [false, true]) {
    testSettings('save completion after leaving is safe, failure=$saveFails', (
      tester,
    ) async {
      pendingWrite = Completer<void>();
      failWrites = saveFails;
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(modeCard(DrivingMode.navigation));
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
  testSettings('shows all three mode cards with updated descriptions', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    for (final mode in selectableModes) {
      expect(modeCard(mode), findsOneWidget);
    }
    expectSelected(DrivingMode.normal);
    expect(
      find.descendant(
        of: modeCard(DrivingMode.navigation),
        matching: find.textContaining('Following distance is still tracked'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: modeCard(DrivingMode.pocket),
        matching: find.textContaining('Focus and following distance tracking'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('cannot be switched during a drive'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final mode in selectableModes) {
    testSettings('selecting ${mode.apiValue} persists and survives a reload', (
      tester,
    ) async {
      storedValues['driving_mode'] = switchTargets[mode]!.apiValue;
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      expectSelected(switchTargets[mode]!);

      await tester.tap(modeCard(mode));
      await tester.pumpAndSettle();
      expectSelected(mode);
      expect(storedValues['driving_mode'], mode.apiValue);
      expect(await tester.runAsync(loadDrivingMode), mode);
      expect(writeCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      expectSelected(mode);
      expect(writeCount, 1);
    });
  }

  testSettings('tapping the selected mode does not write again', (
    tester,
  ) async {
    storedValues['driving_mode'] = 'pocket';
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    await tester.tap(modeCard(DrivingMode.pocket));
    await tester.pumpAndSettle();
    expect(writeCount, 0);
    expectSelected(DrivingMode.pocket);
  });

  test('driving mode API values, labels and tracking flags', () {
    expect(
      [for (final mode in DrivingMode.values) mode.apiValue],
      ['regular', 'navigation', 'pocket'],
    );
    expect(DrivingModeJson.fromApiValue('pocket'), DrivingMode.pocket);
    expect(DrivingModeJson.fromApiValue('navigation'), DrivingMode.navigation);
    expect(DrivingModeJson.fromApiValue('regular'), DrivingMode.normal);
    // Unknown or legacy values fall back to Regular
    expect(DrivingModeJson.fromApiValue('unknown'), DrivingMode.normal);
    expect(DrivingMode.pocket.label, 'Pocket');
    expect(
      [for (final mode in DrivingMode.values) mode.tracksFocus],
      [true, false, false],
    );
    expect(
      [for (final mode in DrivingMode.values) mode.tracksFollowingDistance],
      [true, true, false],
    );
  });

  testSettings('voice feedback loads and saves the shared preference', (
    tester,
  ) async {
    storedValues['live_voice_feedback'] = 'false';
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(storedValues['live_voice_feedback'], 'true');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testSettings('an unrecognized stored mode loads as Regular', (tester) async {
    storedValues['driving_mode'] = 'legacy-value';
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    expectSelected(DrivingMode.normal);
  });
}
