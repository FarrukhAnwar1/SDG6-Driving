// Decides where a user should land right after they're authenticated.
// If every required permission is already granted, this skips
// PermissionsGateScreen entirely and starts background location tracking itself.
// Otherwise it falls back to PermissionsGateScreen so the user can grant what's missing.
// Permissions bypass for browser development.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../screens/home_screen.dart';
import '../screens/permissions_gate_screen.dart';
import 'background_location_service.dart';
import 'permissions_config.dart';
import 'api_config.dart';

Future<Widget> postAuthDestination() async {
  final skipNativeSetup =
      kIsWeb && kDebugMode && ApiConfig.environmentName == 'dev_browser';
  if (!skipNativeSetup) {
    final allGranted = await hasAllRequiredPermissionsGranted();
    if (!allGranted) return const PermissionsGateScreen();
    await BackgroundLocationService.start();
  }
  return const HomePage();
}
