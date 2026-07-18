// Decides where a user should land right after they're authenticated.
// If every required permission is already granted, this skips
// PermissionsGateScreen entirely and starts background location tracking itself.
// Otherwise it falls back to PermissionsGateScreen so the user can grant what's missing.
import 'package:flutter/material.dart';
import '../screens/home_screen.dart';
import '../screens/permissions_gate_screen.dart';
import 'background_location_service.dart';
import 'permissions_config.dart';

Future<Widget> postAuthDestination() async {
  final allGranted = await hasAllRequiredPermissionsGranted();
  if (!allGranted) return const PermissionsGateScreen();

  await BackgroundLocationService.start();
  return const HomePage();
}
