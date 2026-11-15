// App Root
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'widgets/auth/auth_gate.dart';
import 'widgets/driving/background_location_service.dart';
import 'widgets/theme/app_theme.dart';
import 'widgets/theme/theme_settings.dart';
import 'widgets/voice_feedback/voice_feedback_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await themeSettings.load();
  } catch (error) {
    debugPrint('Could not load theme preference: $error');
  }
  try {
    await voiceFeedbackSettings.load();
  } catch (error) {
    debugPrint('Could not load voice feedback preference: $error');
  }
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) {
    runApp(const MyApp());
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  StreamSubscription<Position>? _themeLocationSubscription;
  Timer? _themeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    themeSettings.addListener(_syncAutoTheme);
    _syncAutoTheme();
  }

  void _syncAutoTheme() {
    if (themeSettings.autoSwitch) {
      if (_themeTimer != null) return;
      _themeTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => themeSettings.refreshDaylight(),
      );
      // Reuse the existing GPS feed; theme switching never starts tracking.
      _themeLocationSubscription = BackgroundLocationService.positionStream
          .listen(_updateThemeLocation);
      unawaited(_restoreThemeLocation());
    } else {
      _themeTimer?.cancel();
      _themeTimer = null;
      unawaited(_themeLocationSubscription?.cancel());
      _themeLocationSubscription = null;
    }
  }

  void _updateThemeLocation(Position position) {
    themeSettings.updateLocation(position.latitude, position.longitude);
  }

  Future<void> _restoreThemeLocation() async {
    final latest = BackgroundLocationService.lastPosition;
    if (latest != null) {
      _updateThemeLocation(latest);
      return;
    }
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (mounted &&
          themeSettings.autoSwitch &&
          BackgroundLocationService.lastPosition == null &&
          position != null) {
        _updateThemeLocation(position);
      }
    } catch (_) {
      // Stay dark until the existing, permission-gated GPS feed supplies a fix.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && themeSettings.autoSwitch) {
      themeSettings.refreshDaylight();
      unawaited(_restoreThemeLocation());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    themeSettings.removeListener(_syncAutoTheme);
    _themeTimer?.cancel();
    unawaited(_themeLocationSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeSettings,
      builder: (context, child) => MaterialApp(
        title: 'Login',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeSettings.themeMode,
        home: const AuthGate(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
