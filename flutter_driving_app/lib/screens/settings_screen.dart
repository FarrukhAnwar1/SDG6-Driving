import 'package:flutter/material.dart';
import '../widgets/driving_mode.dart';
import '../widgets/error_banner.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  DrivingMode _drivingMode = DrivingMode.normal;
  bool _isLoading = true;
  bool _isSaving = false;
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
      if (!mounted) return;

      setState(() {
        _drivingMode = mode;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loadError = 'Could not load your driving mode. Please try again.';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                        'Use this mode when you are not using your phone for navigation. ',
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
                        'Focus tracking will be disabled and will not affect your grade.',
                    isSelected: _drivingMode == DrivingMode.navigation,
                    onTap: _isSaving
                        ? null
                        : () => _updateDrivingMode(DrivingMode.navigation),
                  ),

                  if (_isSaving) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: const Text('Saving driving mode...'),
                    ),
                  ],

                  const SizedBox(height: 24),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'The selected mode will apply to your next drive.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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
                              color: colorScheme.primary,
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
