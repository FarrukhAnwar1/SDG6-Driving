// Single source of truth for "what permissions does this app require, and
// are they all currently granted?" Used by PermissionsGateScreen to build
// its checklist, and by the login/auth-gate flows to decide whether a
// user can skip that screen entirely because they already granted
// everything in a previous session.
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

const int kManageExternalStorageMinSdk = 30;

// Must match a key in Info.plist's NSLocationTemporaryUsageDescriptionDictionary
const String kPreciseLocationPurposeKey = 'PreciseLocationUsage';

// Determine API-level specific storage permission for the current device
Future<Permission> storagePermissionForDevice() async {
  if (!Platform.isAndroid) return Permission.storage;
  final androidInfo = await DeviceInfoPlugin().androidInfo;
  return androidInfo.version.sdkInt >= kManageExternalStorageMinSdk
      ? Permission.manageExternalStorage
      : Permission.storage;
}

// Every permission the app requires before letting a user into the rest of the app
Future<List<Permission>> requiredPermissions() async {
  return [
    Permission.locationWhenInUse,
    Permission.locationAlways,
    Permission.camera,
    await storagePermissionForDevice(),
    if (Platform.isAndroid) Permission.ignoreBatteryOptimizations,
  ];
}

// Quick check for whether every required permission is already granted
// AND location accuracy is already precise (not "approximate")
Future<bool> hasAllRequiredPermissionsGranted() async {
  final permissions = await requiredPermissions();

  final statuses = await Future.wait(permissions.map((p) => p.status));
  if (statuses.any((status) => !status.isGranted)) return false;

  final accuracy = await Geolocator.getLocationAccuracy();
  return accuracy == LocationAccuracyStatus.precise;
}
