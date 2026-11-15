import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'change_password_screen.dart';
import 'login_screen.dart';
import '../widgets/auth/auth_storage.dart';
import '../widgets/driving/background_location_service.dart';
import '../widgets/driving/driving_mode.dart';
import '../widgets/driving_reports/pending_report_store.dart';
import '../widgets/shared/api_config.dart';
import '../widgets/shared/error_banner.dart';
import '../widgets/theme/theme_settings.dart';

import '../widgets/voice_feedback/voice_feedback_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.ownerUserId});

  final String? ownerUserId;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  DrivingMode _drivingMode = DrivingMode.normal;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDeleting = false;
  String? _loadError;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDrivingMode();
  }

  Future<void> _loadDrivingMode() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final mode = await loadDrivingMode();
      await voiceFeedbackSettings.load();
      await themeSettings.load();
      if (!mounted) return;

      setState(() {
        _drivingMode = mode;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loadError = 'Could not load your settings. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _updateDrivingMode(DrivingMode newMode) async {
    if (_isSaving || newMode == _drivingMode) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      await newMode.save();
      if (!mounted) return;

      setState(() {
        _drivingMode = newMode;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _errorMessage = 'Could not save your driving mode. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _updateVoiceFeedback(bool enabled) async {
    try {
      await voiceFeedbackSettings.setEnabled(enabled);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save voice feedback. Please try again.'),
        ),
      );
    }
  }

  Future<void> _updateTheme({bool? autoSwitch, bool? dark}) async {
    try {
      if (autoSwitch != null) {
        await themeSettings.setAutoSwitch(autoSwitch);
      } else if (dark != null) {
        await themeSettings.setDark(dark);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save your theme. Please try again.'),
        ),
      );
    }
  }

  Future<void> _openChangePassword() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ChangePasswordPage()));

    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your password was updated.')),
      );
    }
  }

  Future<void> _confirmAndDeleteAccount() async {
    if (_isDeleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This will permanently delete your account. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _deleteAccount();
  }

  Future<void> _deleteAccount() async {
    if (_isDeleting) return;

    setState(() {
      _isDeleting = true;
    });

    try {
      final token = await AuthStorage.readToken();
      if (token == null) {
        _goToLogin();
        return;
      }
      final response = await http.delete(
        Uri.parse('${ApiConfig.baseUrl}/users/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      debugPrint('DELETE ACCOUNT STATUS: ${response.statusCode}');

      if (response.statusCode == 204) {
        final owner = widget.ownerUserId ?? AuthStorage.userIdFromToken(token);
        if (owner != null) await PendingReportStore.clear(owner);
        await BackgroundLocationService.stop();
        await AuthStorage.deleteToken();
        _goToLogin();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not delete account. Please try again.'),
          ),
        );
      }
    } catch (e) {
      debugPrint('DELETE ACCOUNT ERROR: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not connect to backend.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  void _goToLogin() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDeleting,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ErrorBanner(message: _loadError!),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _loadDrivingMode,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      'Driving Mode',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap a mode to choose how your driving behavior will be monitored during your next trip.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),

                    if (_errorMessage != null) ...[
                      ErrorBanner(message: _errorMessage!),
                      const SizedBox(height: 12),
                    ],

                    _ModeDescriptionCard(
                      icon: Icons.directions_car_outlined,
                      title: 'Regular Mode',
                      description:
                          'Use this mode when you are not using your phone for navigation. '
                          'Tracks speed, smoothness, focus, and following distance.',
                      isSelected: _drivingMode == DrivingMode.normal,
                      onTap: _isSaving
                          ? null
                          : () => _updateDrivingMode(DrivingMode.normal),
                    ),

                    const SizedBox(height: 12),

                    _ModeDescriptionCard(
                      icon: Icons.navigation_outlined,
                      title: 'Navigation Mode',
                      description:
                          'Use this mode when your phone is being used for navigation. '
                          'Focus tracking will be disabled and will not affect your grade. '
                          'Following distance is still tracked.',
                      isSelected: _drivingMode == DrivingMode.navigation,
                      onTap: _isSaving
                          ? null
                          : () => _updateDrivingMode(DrivingMode.navigation),
                    ),

                    const SizedBox(height: 12),

                    _ModeDescriptionCard(
                      icon: Icons.phone_android_outlined,
                      title: 'Pocket Mode',
                      description:
                          'Use this mode when your phone is in your pocket, a bag, or otherwise '
                          'cannot see the road. Focus and following distance tracking will both '
                          'be disabled and will not affect your grade.',
                      isSelected: _drivingMode == DrivingMode.pocket,
                      onTap: _isSaving
                          ? null
                          : () => _updateDrivingMode(DrivingMode.pocket),
                    ),

                    if (_isSaving) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: const Text('Saving driving mode...'),
                      ),
                    ],

                    const SizedBox(height: 24),

                    Text(
                      'Personalization',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),

                    // Live Voice Feedback toggle
                    Card(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: voiceFeedbackSettings,
                        builder: (context, isEnabled, child) {
                          return SwitchListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            title: Text(
                              'Live Voice Feedback',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'Receive spoken driving alerts during trips',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                            secondary: const Icon(Icons.record_voice_over),
                            value: isEnabled,
                            onChanged: voiceFeedbackSettings.isSaving
                                ? null
                                : _updateVoiceFeedback,
                          );
                        },
                      ),
                    ),

                    ListenableBuilder(
                      listenable: themeSettings,
                      builder: (context, child) => Column(
                        children: [
                          Card(
                            child: SwitchListTile(
                              key: const ValueKey('auto-theme-switch'),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              title: Text(
                                'Auto Theme Switching',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                themeSettings.waitingForLocation
                                    ? 'Waiting for your location. Dark theme is used until it is available.'
                                    : 'Use light theme from sunrise to sunset at your location, and dark theme at night.',
                              ),
                              secondary: const Icon(Icons.brightness_auto),
                              value: themeSettings.autoSwitch,
                              onChanged: themeSettings.isSaving
                                  ? null
                                  : (value) => _updateTheme(autoSwitch: value),
                            ),
                          ),
                          if (!themeSettings.autoSwitch)
                            Card(
                              child: SwitchListTile(
                                key: const ValueKey('dark-theme-switch'),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                title: Text(
                                  'Dark Theme',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                subtitle: Text(
                                  themeSettings.isDark
                                      ? 'Dark theme selected'
                                      : 'Light theme selected',
                                ),
                                secondary: Icon(
                                  themeSettings.isDark
                                      ? Icons.dark_mode_outlined
                                      : Icons.light_mode_outlined,
                                ),
                                value: themeSettings.isDark,
                                onChanged: themeSettings.isSaving
                                    ? null
                                    : (value) => _updateTheme(dark: value),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                    Text(
                      'Account',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: const Text('Change Password'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _isDeleting ? null : _openChangePassword,
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: _isDeleting
                            ? const SizedBox(
                                height: 24,
                                width: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_outline),
                        iconColor: Theme.of(context).colorScheme.error,
                        textColor: Theme.of(context).colorScheme.error,
                        title: Text(
                          _isDeleting
                              ? 'Deleting Account...'
                              : 'Delete Account',
                        ),
                        onTap: _isDeleting ? null : _confirmAndDeleteAccount,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ModeDescriptionCard extends StatelessWidget {
  const _ModeDescriptionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      selected: isSelected,
      enabled: onTap != null,
      inMutuallyExclusiveGroup: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: isSelected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (isSelected)
                            Icon(
                              Icons.check_circle,
                              color: colorScheme.onPrimaryContainer,
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(description),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
