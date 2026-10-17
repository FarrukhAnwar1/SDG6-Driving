// Basic home screen shown after a successful login
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';
import 'change_password_screen.dart';
import 'live_dashboard_screen.dart';
import 'analytics_screen.dart';
import 'driving_family_screen.dart';
import 'settings_screen.dart';
import '../widgets/auth_storage.dart';
import '../widgets/api_config.dart';
import '../widgets/background_location_service.dart';
import '../widgets/driving_mode.dart';
import '../widgets/error_banner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // State variables
  bool _isLoading = true;
  bool _isDeleting = false;
  bool _isStartingTrip = false;
  String? _username;
  int? _userId;
  String? _userEmail;
  String? _loadError;
  String? _startTripError;

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    final token = await AuthStorage.readToken();
    if (token == null) {
      _goToLogin();
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      debugPrint('ME STATUS: ${response.statusCode}');

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _username = data['username'] as String?;
          _userId = data['id'] as int;
          _userEmail = data['email'] as String;
          _isLoading = false;
        });
      } else if (response.statusCode == 401) {
        // Token expired or invalid
        await AuthStorage.deleteToken();
        _goToLogin();
      } else {
        setState(() {
          _loadError = 'Could not load your profile. Please try again.';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('LOAD USER ERROR: $e');
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not connect to backend.';
        _isLoading = false;
      });
    }
  }

  void _goToLogin() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  Future<void> _logout() async {
    await BackgroundLocationService.stop();
    await AuthStorage.deleteToken();
    _goToLogin();
  }

  // Reads the driving mode from storage and starts the trip with that mode
  Future<void> _startTrip() async {
    if (!mounted || _isStartingTrip) return;
    setState(() {
      _isStartingTrip = true;
      _startTripError = null;
    });

    final DrivingMode drivingMode;
    try {
      drivingMode = await loadDrivingMode();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _startTripError = 'Could not load your driving mode. Please try again.';
      });
      return;
    } finally {
      if (mounted) setState(() => _isStartingTrip = false);
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveDashboardScreen(drivingMode: drivingMode),
      ),
    );
  }

  Future<void> _openAnalytics() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AnalyticsScreen()));
  }

  Future<void> _openDrivingFamily() async {
    final userId = _userId;
    final userEmail = _userEmail;
    if (userId == null || userEmail == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DrivingFamilyScreen(
          currentUserId: userId,
          currentUserEmail: userEmail,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  Future<void> _openChangePassword() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => ChangePasswordPage()));

    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your password was updated.')),
      );
    }
  }

  Future<void> _confirmAndDeleteAccount() async {
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

    if (confirmed != true) return;
    await _deleteAccount();
  }

  Future<void> _deleteAccount() async {
    if (_isDeleting) return;

    setState(() {
      _isDeleting = true;
    });

    final token = await AuthStorage.readToken();

    try {
      final response = await http.delete(
        Uri.parse('${ApiConfig.baseUrl}/users/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      debugPrint('DELETE ACCOUNT STATUS: ${response.statusCode}');

      if (response.statusCode == 204) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Center(child: _buildBody(context)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }

    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadError = null;
                });
                _loadCurrentUser();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Welcome, ${_username ?? 'there'}!',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          if (_startTripError != null) ...[
            const SizedBox(height: 16),
            ErrorBanner(message: _startTripError!),
            TextButton(onPressed: _startTrip, child: const Text('Retry')),
          ],
          const SizedBox(height: 32),
          IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _isStartingTrip ? null : _startTrip,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Trip'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openAnalytics,
                  icon: const Icon(Icons.insights),
                  label: const Text('View Analytics'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openDrivingFamily,
                  icon: const Icon(Icons.groups_outlined),
                  label: const Text('Driving Family'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Settings'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openChangePassword,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Change Password'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isDeleting ? null : _confirmAndDeleteAccount,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                  icon: _isDeleting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: const Text('Delete Account'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
