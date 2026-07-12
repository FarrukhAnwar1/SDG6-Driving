// Screen that lets a logged-in user change their password
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../widgets/auth_storage.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, required this.baseUrl});

  final String baseUrl;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();

  // Form controllers
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // State variables
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _errorMessage = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    final token = await AuthStorage.readToken();

    if (token == null) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'You have been signed out. Please log in again.';
      });
      return;
    }

    // TODO: replace placeholder API logic with actual logic
    try {
      final response = await http.put(
        Uri.parse('${widget.baseUrl}/users/me/password'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'new_password': _newPasswordController.text}),
      );

      debugPrint('CHANGE PASSWORD STATUS: ${response.statusCode}');

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed successfully.')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      if (response.statusCode == 401) {
        setState(() {
          _errorMessage = 'You have been signed out. Please log in again.';
        });
      } else if (response.statusCode == 400) {
        setState(() {
          _errorMessage =
              _extractErrorMessage(response.body) ??
              'Could not change your password. Please try again.';
        });
      } else {
        setState(() {
          _errorMessage = 'Could not change your password. Please try again.';
        });
      }
    } catch (e) {
      debugPrint('CHANGE PASSWORD ERROR: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not connect to backend.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  String? _extractErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Response body wasn't JSON so fall back to the default message
    }
    return null;
  }

  String? _validateNewPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a new password.';
    }
    if (value.length < 8) {
      return 'Password must be at least 8 characters.';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your new password.';
    }
    if (value != _newPasswordController.text) {
      return 'Passwords do not match.';
    }
    return null;
  }

  void _handleFieldSubmitted(String _) {
    if (!_isSubmitting) {
      _submit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _newPasswordController,
                  obscureText: _obscureNew,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'New password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureNew
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureNew = !_obscureNew),
                    ),
                  ),
                  validator: _validateNewPassword,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirm,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'Confirm new password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: _validateConfirmPassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: _handleFieldSubmitted,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Update password'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
