// Shown immediately after a successful login.
// Blocks entry into the rest of the app until every required permission is granted
// AND until location access is confirmed as precise (not approximate).
// Once everything is granted, it starts continuous background location
// tracking before handing off to Home. Users who already granted everything
// go through with no UI shown at all.
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home_screen.dart';
import '../widgets/background_location_service.dart';

class _RequiredPermission {
  final Permission permission;
  final String title;
  final String rationale;
  final IconData icon;

  const _RequiredPermission({
    required this.permission,
    required this.title,
    required this.rationale,
    required this.icon,
  });
}

const int _manageExternalStorageMinSdk = 30;

// Must match a key in Info.plist's NSLocationTemporaryUsageDescriptionDictionary
const String _preciseLocationPurposeKey = 'PreciseLocationUsage';

class PermissionsGateScreen extends StatefulWidget {
  const PermissionsGateScreen({super.key});

  @override
  State<PermissionsGateScreen> createState() => _PermissionsGateScreenState();
}

class _PermissionsGateScreenState extends State<PermissionsGateScreen>
    with WidgetsBindingObserver {
  Map<Permission, PermissionStatus> _statuses = {};
  LocationAccuracyStatus? _accuracyStatus;
  bool _isChecking = true;
  bool _isRequesting = false;
  bool _hasRequestedOnce = false;
  int? _androidSdkInt;
  List<_RequiredPermission> _requiredPermissions = [];

  bool get _usesManageExternalStorage =>
      Platform.isAndroid &&
      (_androidSdkInt ?? 0) >= _manageExternalStorageMinSdk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      _androidSdkInt = androidInfo.version.sdkInt;
    }
    _requiredPermissions = _buildRequiredPermissions();
    await _refreshStatuses(proceedIfGranted: true);
  }

  // Built at runtime (rather than as a static const list) because the
  // storage permission depends on the detected Android SDK version
  List<_RequiredPermission> _buildRequiredPermissions() {
    return [
      const _RequiredPermission(
        permission: Permission.locationWhenInUse,
        title: 'Location',
        rationale: 'Used to get your speed with an accurate location.',
        icon: Icons.location_on_outlined,
      ),
      const _RequiredPermission(
        permission: Permission.locationAlways,
        title: 'Background location',
        rationale:
            'Lets us keep tracking your speed when the app is closed or '
            'your screen is off.',
        icon: Icons.location_history_outlined,
      ),
      const _RequiredPermission(
        permission: Permission.camera,
        title: 'Camera',
        rationale: 'Used for computer vision and driving recordings.',
        icon: Icons.camera_alt_outlined,
      ),
      _RequiredPermission(
        permission: _usesManageExternalStorage
            ? Permission.manageExternalStorage
            : Permission.storage,
        title: 'Storage',
        rationale:
            "Used to save and load recordings anywhere on your device's "
            'storage.',
        icon: Icons.folder_outlined,
      ),
      if (Platform.isAndroid)
        const _RequiredPermission(
          permission: Permission.ignoreBatteryOptimizations,
          title: 'Unrestricted battery usage',
          rationale:
              'Keeps the app running in the background instead of being paused '
              'to save battery.',
          icon: Icons.battery_charging_full_outlined,
        ),
    ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If the user went to the OS Settings app to flip a permission on,
    // re-check as soon as they come back instead of making them tap again
    if (state == AppLifecycleState.resumed && _requiredPermissions.isNotEmpty) {
      _refreshStatuses(proceedIfGranted: true);
    }
  }

  bool get _locationIsPrecise =>
      _accuracyStatus == LocationAccuracyStatus.precise;

  bool get _allGranted {
    final permissionsOk = _requiredPermissions.every(
      (p) => _statuses[p.permission]?.isGranted ?? false,
    );
    return permissionsOk && _locationIsPrecise;
  }

  bool get _anyPermanentlyDenied => _requiredPermissions.any(
    (p) => _statuses[p.permission]?.isPermanentlyDenied ?? false,
  );

  // Once we've asked at least once and location is granted but still shows
  // as approximate, the OS won't prompt again, the user has to flip
  // "Precise Location" on for the app from Settings themselves
  bool get _preciseLocationStuck =>
      _hasRequestedOnce &&
      !_locationIsPrecise &&
      (_statuses[Permission.locationWhenInUse]?.isGranted ?? false);

  bool get _needsSettings => _anyPermanentlyDenied || _preciseLocationStuck;

  Future<LocationAccuracyStatus?> _checkAccuracyIfLocationGranted(
    Map<Permission, PermissionStatus> statuses,
  ) async {
    if (!(statuses[Permission.locationWhenInUse]?.isGranted ?? false)) {
      return null;
    }
    return Geolocator.getLocationAccuracy();
  }

  Future<void> _refreshStatuses({bool proceedIfGranted = false}) async {
    final entries = await Future.wait(
      _requiredPermissions.map((p) async {
        final status = await p.permission.status;
        return MapEntry(p.permission, status);
      }),
    );
    final statuses = Map.fromEntries(entries);
    final accuracy = await _checkAccuracyIfLocationGranted(statuses);

    if (!mounted) return;

    setState(() {
      _statuses = statuses;
      _accuracyStatus = accuracy;
      _isChecking = false;
    });

    if (proceedIfGranted && _allGranted) {
      _proceedToHome();
    }
  }

  Future<void> _requestAll() async {
    setState(() => _isRequesting = true);

    // "Always" location must be requested only after "when in use" is
    // granted. MANAGE_EXTERNAL_STORAGE shows no in-app dialog at all,
    // requesting it sends the user straight to a system Settings screen,
    // so, like locationAlways, it's requested on its own rather than
    // batched with the permissions that show a normal in-app dialog.
    final batchPermissions = _requiredPermissions
        .map((p) => p.permission)
        .where(
          (p) =>
              p != Permission.locationAlways &&
              p != Permission.manageExternalStorage,
        )
        .toList();

    var results = await batchPermissions.request();

    final PermissionStatus alwaysStatus;
    if (results[Permission.locationWhenInUse]?.isGranted ?? false) {
      alwaysStatus = await Permission.locationAlways.request();
    } else {
      alwaysStatus = await Permission.locationAlways.status;
    }
    results = {...results, Permission.locationAlways: alwaysStatus};

    if (_usesManageExternalStorage) {
      final manageStorageStatus = await Permission.manageExternalStorage
          .request();
      results = {
        ...results,
        Permission.manageExternalStorage: manageStorageStatus,
      };
    }

    var accuracy = await _checkAccuracyIfLocationGranted(results);
    if (accuracy != null && accuracy != LocationAccuracyStatus.precise) {
      accuracy = await Geolocator.requestTemporaryFullAccuracy(
        purposeKey: _preciseLocationPurposeKey,
      );
    }

    if (!mounted) return;

    setState(() {
      _statuses = results;
      _accuracyStatus = accuracy;
      _isRequesting = false;
      _hasRequestedOnce = true;
    });

    if (_allGranted) {
      _proceedToHome();
    }
  }

  Future<void> _proceedToHome() async {
    await BackgroundLocationService.start();

    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // No back button escape from the permissions gate
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Permissions required'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: _isChecking
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This app needs a few permissions to work',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Please allow all of the following to continue.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Expanded(
            child: ListView.separated(
              // +1 for the "full accuracy" row, which sits alongside the
              // location permission but isn't a Permission itself
              itemCount: _requiredPermissions.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == _requiredPermissions.length) {
                  return ListTile(
                    leading: const Icon(Icons.my_location_outlined),
                    title: const Text('Full location accuracy'),
                    subtitle: const Text(
                      'Precise location must be on (not "approximate").',
                    ),
                    trailing: Icon(
                      _locationIsPrecise
                          ? Icons.check_circle
                          : Icons.error_outline,
                      color: _locationIsPrecise ? Colors.green : Colors.orange,
                    ),
                  );
                }

                final item = _requiredPermissions[index];
                final granted = _statuses[item.permission]?.isGranted ?? false;

                return ListTile(
                  leading: Icon(item.icon),
                  title: Text(item.title),
                  subtitle: Text(item.rationale),
                  trailing: Icon(
                    granted ? Icons.check_circle : Icons.error_outline,
                    color: granted ? Colors.green : Colors.orange,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_needsSettings) ...[
            Text(
              _anyPermanentlyDenied
                  ? "You've permanently denied one or more permissions. "
                        'Please enable them from Settings to continue.'
                  : 'Precise location is turned off for this app. Please '
                        'enable "Precise Location" in Settings to continue.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: openAppSettings,
              child: const Text('Open settings'),
            ),
          ] else
            FilledButton(
              onPressed: _isRequesting ? null : _requestAll,
              child: _isRequesting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Grant permissions'),
            ),
        ],
      ),
    );
  }
}
