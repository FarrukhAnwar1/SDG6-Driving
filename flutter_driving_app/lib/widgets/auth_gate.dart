// Checks for a stored session on app launch and routes to the home screen
// if it's still valid, otherwise to the login screen
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../screens/login_screen.dart';
import '../screens/home_screen.dart';
import 'auth_storage.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Backend URL (Android emulator)
  static const String baseUrl = 'http://10.0.2.2:8000';

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final token = await AuthStorage.readToken();

    Widget destination = const LoginPage();

    if (token != null) {
      try {
        final response = await http.get(
          Uri.parse('$baseUrl/me'),
          headers: {'Authorization': 'Bearer $token'},
        );

        debugPrint('SESSION CHECK STATUS: ${response.statusCode}');

        if (response.statusCode == 200) {
          destination = const HomePage();
        } else {
          await AuthStorage.deleteToken();
        }
      } catch (e) {
        debugPrint('SESSION CHECK ERROR: $e');
      }
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => destination));
  }

  @override
  Widget build(BuildContext context) {
    // Simple splash while checking for a valid session
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
